import AppKit
import SwiftUI
import WrdsKit

/// A borderless, non-activating panel that can still become key — the two AppKit defaults that
/// combination needs overridden. A borderless window's `canBecomeKey` defaults to `false`, which
/// would leave the palette on screen with a search field that never accepts a keystroke;
/// `canBecomeMain` is turned off because this is a palette, not a document window, and should never
/// be offered as one by anything that walks the app's window list.
///
/// `cancelOperation(_:)` is what Escape resolves to by default when nothing more specific handles it
/// — including from inside a focused text field, which forwards unhandled editing commands up the
/// responder chain. Overriding it here is a second, AppKit-level guarantee that Escape closes the
/// palette, alongside `PickerView`'s own `.onExitCommand`.
///
/// Not `private`: `FormPanelController` needs the identical shim for its own non-activating panel,
/// and this class has no state of its own worth duplicating a second time for.
final class NonActivatingKeyPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// The floating search palette the global hotkey and the menu's "Open Picker" item both show.
///
/// One instance lives for the app's lifetime and is shown and hidden rather than rebuilt on every
/// invocation: AppKit tears a closed window down asynchronously, so a fresh `NSPanel` per show could
/// leak one if the palette were reopened before the previous one had finished going away. What *is*
/// rebuilt on every show is the SwiftUI content — a fresh `PickerView` with empty search text and the
/// first result selected, which is what "no recents section" and "empty search shows everything"
/// promise: reopening the palette should not resume whatever was half-typed the last time.
///
/// ## Why `.nonactivatingPanel` is not optional
///
/// This is the one piece of AppKit plumbing the rest of the picker depends on for correctness, not
/// just polish. `TextInjector` posts synthetic keystrokes to whatever window currently holds key
/// status; `ExpansionEngine.expand(_:inApp:)` only decides *which app's settings* apply, not which
/// window the keystrokes land in. If showing this panel activated F Wrds, the panel's own search
/// field would become the key window and an expansion chosen here would type into it — or into
/// nothing, once the panel has closed — rather than into the app the hotkey was pressed in.
/// `.nonactivatingPanel` is what lets this panel become key for typed search input **without** F Wrds
/// becoming the active application, so the target app never stops being the frontmost app and regains
/// key status the moment this panel is ordered out.
@MainActor
final class PickerPanel: NSObject {
    /// How long to wait, after ordering the panel out, before handing the chosen snippet to the
    /// engine when the palette was opened by its **hotkey**. `orderOut(_:)` updates this app's own
    /// notion of key status immediately, but nothing here can observe the window server having
    /// finished reassigning it back to the app that lent it — this is that margin. Short, because the
    /// hotkey path never activates F Wrds in the first place (`.nonactivatingPanel`'s whole point), so
    /// all that is being waited out is `orderOut` itself settling, with no closing animation in front
    /// of it the way an `NSMenu` fading away has.
    private static let hotkeyCloseDelay: TimeInterval = 0.05

    /// The same wait, for the palette opened from the menu's **"Open Picker" item** instead — a
    /// different race, not a smaller version of the one above. Clicking any menu bar item transiently
    /// activates F Wrds (`AppModel+Picker.swift`'s `openPickerFromMenu()` says so at its call site),
    /// exactly the way clicking a snippet in the menu does for `AppModel.expandFromMenu` — and that
    /// activation is the same class of race `expandFromMenu`'s own 200 ms already exists to wait out.
    /// This reuses that value rather than guessing a second number for what is, from the window
    /// server's point of view, the same problem; see `AppModel.menuCloseDelay`'s own note for the
    /// cross-reference back.
    private static let menuCloseDelay: TimeInterval = 0.2

    /// Called with `true` as the palette goes on screen and `false` as it leaves, through every path
    /// either can happen by — the hotkey, the menu item, a selection, Escape, a click outside.
    ///
    /// It exists for `ExpansionEngine.isPanelSuspended`, and the reason is the same
    /// `.nonactivatingPanel` note above read the other way round: because this panel never activates
    /// F Wrds, the app the user was typing in is *still frontmost* while they type into the search
    /// field, and the engine's tap sees every one of those keystrokes as ordinary typing. A query
    /// that happens to spell a trigger would match, and the expansion would land in that document.
    ///
    /// Set once, at construction, and left alone — the same contract the engine's own callbacks
    /// keep. This type still does not reach into `ExpansionEngine` itself; it reports what it did,
    /// and `AppModel` decides what that means, the same separation `show`'s `onExpand` keeps.
    var onVisibilityChanged: ((Bool) -> Void)?

    private var panel: NonActivatingKeyPanel?
    private var hostingController: NSHostingController<PickerView>?

    /// Whether the palette is on screen, so `onVisibilityChanged` fires on changes rather than on
    /// calls: `hide()` is reached from four places and more than one of them can run for a single
    /// dismissal — a selection hides the panel, and the resulting resign-key hides it again.
    private var isVisible = false

    /// Shows the palette, centred on the screen under the mouse pointer, offering `groups` — already
    /// filtered by the caller for whichever app was frontmost when it decided to show this. Picking a
    /// result hides the panel and, once the wait above has let key status return to that app, calls
    /// `onExpand`.
    ///
    /// - Parameter openedFromMenu: `true` when this call came from the menu's "Open Picker" item,
    ///   `false` for the hotkey — see `menuCloseDelay`/`hotkeyCloseDelay` for why the distinction
    ///   changes how long `select(_:openedFromMenu:onExpand:)` waits before injecting.
    func show(
        groups: [PickerGroupEntry], canExpand: Bool, openedFromMenu: Bool,
        onExpand: @escaping (Snippet) -> Void
    ) {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        let view = PickerView(
            groups: groups, canExpand: canExpand,
            onExpand: { [weak self] snippet in
                self?.select(snippet, openedFromMenu: openedFromMenu, onExpand: onExpand)
            },
            onCancel: { [weak self] in self?.hide() }
        )
        let hostingController = NSHostingController(rootView: view)
        self.hostingController = hostingController
        panel.contentView = hostingController.view

        position(panel)
        // Announced *before* the panel takes the keyboard, not after: the engine has to be
        // suspended by the time the first keystroke aimed at the search field reaches its tap, and
        // the ⌥Space that opened the palette is itself one of those keystrokes.
        setVisible(true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Orders the panel off screen and drops its content, so the next `show` starts from an empty
    /// search rather than resuming this one.
    func hide() {
        panel?.orderOut(nil)
        hostingController = nil
        panel?.contentView = nil
        // After `orderOut`, so that whatever this app suspended is resumed only once the panel has
        // stopped being the window keystrokes are going to.
        setVisible(false)
    }

    /// Reports a change in whether the palette is on screen, and only a change.
    private func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        onVisibilityChanged?(visible)
    }

    /// Hides the panel, then — after `menuCloseDelay` or `hotkeyCloseDelay`, matching how the palette
    /// was opened — hands `snippet` to `onExpand`.
    ///
    /// Hiding first is what makes the wait mean anything, and it also resumes matching (see
    /// `onVisibilityChanged`) a beat before the expansion runs. That ordering is safe rather than
    /// lucky: `onExpand` reaches `ExpansionEngine.expand(_:inApp:)`, which never goes through the
    /// matcher at all, so there is nothing for the resume to race.
    private func select(_ snippet: Snippet, openedFromMenu: Bool, onExpand: @escaping (Snippet) -> Void) {
        hide()
        let delay = openedFromMenu ? Self.menuCloseDelay : Self.hotkeyCloseDelay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            onExpand(snippet)
        }
    }

    private func makePanel() -> NonActivatingKeyPanel {
        let panel = NonActivatingKeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        // Clear rather than white: `PickerView` draws its own rounded, materialed background, and an
        // opaque backing colour would show as square corners behind it.
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.hide() }
        return panel
    }

    /// Centres `panel` on the screen holding the mouse pointer, falling back to the main screen —
    /// `NSScreen.main` alone answers "the screen with this *app's* key window", which during normal
    /// use is nothing, since nothing here has yet made this app frontmost.
    private func position(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2)
        panel.setFrameOrigin(origin)
    }
}

extension PickerPanel: NSWindowDelegate {
    /// "Clicking outside closes": any other window — another app's, or one of F Wrds' own — becoming
    /// key means this one just stopped being it, which for a panel that never activated its app in
    /// the first place is exactly what a click outside looks like.
    func windowDidResignKey(_ notification: Notification) {
        hide()
    }
}
