import AppKit
import SwiftUI
import WrdsKit

/// The floating panel that collects a form snippet's field values before an expansion can proceed.
///
/// One instance lives for the app's lifetime and is shown and hidden rather than rebuilt — the same
/// reason `PickerPanel` does it, and the same `NonActivatingKeyPanel` shim: the panel has to become
/// key so its fields can be typed into, but must not activate F Wrds, or the deletion
/// `ExpansionEngine.completeForm(answers:snippet:match:flow:)` performs would land in the panel rather
/// than in the app the trigger was typed in.
///
/// ## The hand-off back to the origin app
///
/// `completeForm`'s own contract requires the caller to have put focus back in the app the trigger
/// was typed in *before* calling it — this panel took key status away from that app the moment it
/// showed. `submit(_:originBundleID:)` is what does that: it activates the
/// `NSRunningApplication` for the origin bundle ID, then waits for the window server to actually
/// hand it activation — polling isn't trustworthy enough to believe on the very next instant, so
/// this waits for `NSWorkspace.didActivateApplicationNotification` instead, with a timeout as the
/// escape hatch for an app that has quit or stopped responding — and only then calls `onComplete`.
/// If the wait fails, this calls `onCancel` instead of guessing: completing into the wrong app would
/// silently corrupt whatever the user is typing there, and cancelling costs nothing because nothing
/// has been deleted yet.
///
/// ## Multi-field forms
///
/// A snippet can declare more than one form variable, and the engine asks for them one at a time:
/// each `completeForm` re-renders, and a snippet with an unanswered variable left over comes back
/// through `onNeedsForm` again rather than injecting. `completeForm` takes the *complete* answer set
/// on every call — it does not accumulate across calls itself, by design, so the form flow stays
/// restartable — which makes carrying answers forward this panel's job. `accumulatedAnswers` is that
/// carry: `show(...)` merges a fresh variable's fields on top of whatever this panel has already
/// collected for the *same flow*, and clears them the moment a different flow's token arrives, since
/// a different token can only mean the previous flow finished and a new one has started — matching
/// is paused engine-side for the whole time one is pending, so two flows can never overlap.
///
/// The flow token, and not the `TriggerMatch`, is what identifies a flow, and that distinction is
/// load-bearing rather than tidy. `TriggerMatch` is `Equatable` over what was *matched* — snippet
/// ID, typed text, case transform, captures — none of which says *when*. Typing the same trigger
/// twice makes two equal matches, and so does picking the same snippet from the palette twice, whose
/// matches carry an empty `typedText` besides. Keyed on the match, the second run of a snippet with
/// several form variables would find the first run's answers still sitting here, count its own later
/// variables as already answered, and inject those stale values without ever asking about them.
@MainActor
final class FormPanelController: NSObject {
    /// Everything about the `needsForm` hop this panel is answering, bundled into one value so
    /// `show(...)` stays a handful of parameters the way `PickerPanel.show` does rather than growing
    /// one for every field `ExpansionEngine.onNeedsForm` reports.
    struct FormRequest {
        let snippet: Snippet
        let variable: Variable
        let fields: [FormField]
        let match: TriggerMatch
        /// The app the trigger was typed in — `onNeedsForm`'s own trailing parameter, passed
        /// straight through. `nil` means the engine could not name it, in which case submitting has
        /// nowhere safe to restore focus to and is treated as a failure rather than a guess.
        let originBundleID: String?
        /// Which form flow this hop belongs to — `onNeedsForm`'s flow token, passed straight
        /// through and quoted back to `completeForm`/`cancelForm`. See the type doc for why the
        /// `match` above cannot do this job.
        let flow: UUID
    }

    /// How long the origin app has to finish activating before this gives up and cancels instead of
    /// completing into whatever happens to be frontmost.
    private static let activationTimeout: TimeInterval = 1.0

    /// A small offset from the mouse pointer, so the panel does not appear with the cursor sitting
    /// on top of its first field.
    private static let pointerOffset = CGPoint(x: 12, y: -12)

    private var panel: NonActivatingKeyPanel?
    private var hostingController: NSHostingController<FormPanelView>?

    /// The form flow this panel is currently collecting answers for, or `nil` between flows.
    /// Equality against the token `show(...)` is called with next is what tells a continuing
    /// multi-field flow apart from a fresh one — see the type doc.
    private var currentFlow: UUID?
    private var accumulatedAnswers: [String: String] = [:]

    /// Stored rather than threaded through `submit`/`waitForActivation`/`complete` as parameters:
    /// `waitForActivation` hands a closure to `NSWorkspace`'s notification centre, which requires a
    /// `@Sendable` closure, and a plain `([String: String]) -> Void` is not `Sendable` — passing one
    /// as a parameter into that closure is what the compiler rejects. Capturing `self` (weakly) and
    /// reading these back out through `MainActor.assumeIsolated` sidesteps that: only the reference
    /// crosses the boundary, never the closures themselves.
    private var onComplete: (([String: String]) -> Void)?
    private var onCancel: (() -> Void)?
    private var onFailure: ((String) -> Void)?

    private var activationObserver: NSObjectProtocol?
    private var activationTimeoutWorkItem: DispatchWorkItem?

    /// Set for the duration of `hide()`'s own call to `orderOut(_:)`.
    ///
    /// `NSPanel.orderOut(_:)` on a key panel resigns key status *synchronously* — verified against a
    /// throwaway panel, not assumed — which means `windowDidResignKey(_:)` runs nested inside this
    /// flag's call to `hide()`, before `orderOut` has even returned. Every call to `hide()` in this
    /// type is already a decision that has been made — a submit under way, a cancel already in
    /// progress — so a `windowDidResignKey` firing as a side effect of it must not be re-read as a
    /// fresh "the user clicked outside" and call `cancel()` a second, unwanted time on top of
    /// whatever `hide()`'s caller is already doing.
    private var isHidingProgrammatically = false

    /// Shows the panel for one form variable, or brings it back for the next one in the same flow.
    ///
    /// - Parameters:
    ///   - onComplete: called with the accumulated answers, keyed `"<variableName>.<fieldName>"`,
    ///     once the origin app is confirmed frontmost again. The caller's job is exactly
    ///     `engine.completeForm(answers:snippet:match:flow:)` — this type does not reach into
    ///     `ExpansionEngine` itself, the same separation `PickerPanel.show` keeps from
    ///     `AppModel+Picker.swift`.
    ///   - onCancel: called when the user backs out, or when reactivating the origin app fails — the
    ///     caller's job is `engine.cancelForm(flow:)`.
    ///   - onFailure: a short, user-facing reason, called alongside `onCancel` only when there is one
    ///     worth surfacing — a missing or unresponsive origin app. A deliberate Escape or click
    ///     outside calls `onCancel` alone.
    func show(
        _ request: FormRequest,
        onComplete: @escaping ([String: String]) -> Void,
        onCancel: @escaping () -> Void,
        onFailure: @escaping (String) -> Void
    ) {
        if currentFlow != request.flow {
            accumulatedAnswers = [:]
        }
        currentFlow = request.flow
        self.onComplete = onComplete
        self.onCancel = onCancel
        self.onFailure = onFailure

        let panel = self.panel ?? makePanel()
        self.panel = panel

        let view = FormPanelView(
            variable: request.variable, fields: request.fields,
            onSubmit: { [weak self] answers in
                self?.submit(answers, originBundleID: request.originBundleID)
            },
            onCancel: { [weak self] in self?.cancel() }
        )
        let hostingController = NSHostingController(rootView: view)
        self.hostingController = hostingController
        panel.contentView = hostingController.view
        // The view has a fixed width and an intrinsic height from its rows — sizing the panel to fit
        // is what keeps it "compact" for one field and taller for several, rather than a size picked
        // to fit the biggest form in the library.
        panel.setContentSize(hostingController.view.fittingSize)

        position(panel)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Orders the panel off screen and drops its content, matching `PickerPanel.hide()` — the next
    /// `show` (a fresh flow, or the next field of this one) starts from a clean SwiftUI view rather
    /// than resuming whatever was on screen before.
    private func hide() {
        isHidingProgrammatically = true
        panel?.orderOut(nil)
        isHidingProgrammatically = false
        hostingController = nil
        panel?.contentView = nil
    }

    /// Escape, or a click outside. Nothing has been deleted, so this only has to stop waiting and
    /// tell the caller.
    private func cancel() {
        clearActivationWait()
        hide()
        currentFlow = nil
        accumulatedAnswers = [:]
        onCancel?()
    }

    /// One field's worth of answers came back from the panel. Merges them into whatever this flow
    /// has already collected and starts the hand-off back to `originBundleID`.
    private func submit(_ answers: [String: String], originBundleID: String?) {
        accumulatedAnswers.merge(answers) { _, new in new }
        hide()

        guard let originBundleID else {
            fail(reason: String(localized: "F Wrds couldn't tell which app to send the answer back to."))
            return
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: originBundleID)
            .first
        else {
            fail(reason: String(localized: "That app isn't running any more."))
            return
        }

        // Already frontmost — most of the time, since `.nonactivatingPanel` never took activation
        // away from it in the first place. No point waiting for a notification that has already
        // happened.
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == originBundleID {
            complete()
            return
        }
        app.activate()
        waitForActivation(targetBundleID: originBundleID)
    }

    /// Watches for `targetBundleID` becoming frontmost, or gives up after `activationTimeout`.
    /// Whichever happens first wins and cancels the other.
    private func waitForActivation(targetBundleID: String) {
        clearActivationWait()
        let center = NSWorkspace.shared.notificationCenter
        activationObserver = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let activatedBundleID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication)?.bundleIdentifier
            guard activatedBundleID == targetBundleID else { return }
            // `queue: .main` makes the hop free and ordered, the same reasoning
            // `AppModel.observeAppSwitches()` uses for its own app-switch observer.
            MainActor.assumeIsolated {
                self?.finishActivationWait(succeeded: true)
            }
        }

        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.finishActivationWait(succeeded: false)
            }
        }
        activationTimeoutWorkItem = timeoutWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.activationTimeout, execute: timeoutWorkItem)
    }

    private func finishActivationWait(succeeded: Bool) {
        clearActivationWait()
        if succeeded {
            complete()
        } else {
            fail(reason: String(localized: "The app didn't come back to the front in time."))
        }
    }

    private func clearActivationWait() {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        activationTimeoutWorkItem?.cancel()
        activationTimeoutWorkItem = nil
    }

    private func complete() {
        onComplete?(accumulatedAnswers)
        // Not cleared here: if `onComplete` leads to another `onNeedsForm` for the same flow, the
        // next `show(...)` arrives with the same flow token and is meant to see these answers still
        // sitting here. If it does not, the flow is over, and the next one — necessarily carrying a
        // freshly minted token — clears them by simply not matching `currentFlow`.
    }

    private func fail(reason: String) {
        // Already cleared when this is reached from `finishActivationWait`, but not when it is
        // reached straight from `submit`'s own guards — no `waitForActivation` call means there is
        // nothing pending, but clearing unconditionally costs nothing and removes the need to trust
        // that every call site got there the same way.
        clearActivationWait()
        currentFlow = nil
        accumulatedAnswers = [:]
        onCancel?()
        onFailure?(reason)
    }

    private func makePanel() -> NonActivatingKeyPanel {
        let panel = NonActivatingKeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 160),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        // Clear rather than white: `FormPanelView` draws its own rounded, materialed background, and
        // an opaque backing colour would show as square corners behind it.
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.cancel() }
        return panel
    }

    /// Positions the panel just past the mouse pointer, offset so the cursor is not sitting on top
    /// of the first field, and clamped to the screen holding the pointer so it cannot land partly
    /// off screen near an edge.
    private func position(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        var origin = NSPoint(
            x: mouseLocation.x + Self.pointerOffset.x,
            y: mouseLocation.y + Self.pointerOffset.y - size.height)
        origin.x = min(max(origin.x, frame.minX), frame.maxX - size.width)
        origin.y = min(max(origin.y, frame.minY), frame.maxY - size.height)
        panel.setFrameOrigin(origin)
    }
}

extension FormPanelController: NSWindowDelegate {
    /// "Clicking outside cancels" — the same reasoning as `PickerPanel.windowDidResignKey`, guarded
    /// by `isHidingProgrammatically` for the reason documented at that property: this panel, unlike
    /// `PickerPanel`, has a call — `submit(_:originBundleID:)` — that hides itself for a reason other
    /// than cancelling, and `orderOut(_:)` resigning key status synchronously means this method would
    /// otherwise run in the middle of that call and read it as a click outside.
    ///
    /// A menu-style `Picker`'s dropdown is expected **not** to trigger this at all: AppKit's menu
    /// tracking runs its own event loop without handing key status to a separate `NSWindow`, so the
    /// panel that opened it is documented to stay key for as long as the menu is open. That
    /// expectation is based on AppKit's documented menu-tracking behaviour, not on an interactive
    /// click test in this headless build environment — worth a manual check the first time this
    /// panel is driven by hand.
    func windowDidResignKey(_ notification: Notification) {
        guard !isHidingProgrammatically else { return }
        cancel()
    }
}
