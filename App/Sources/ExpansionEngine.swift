import Foundation
import WrdsKit

/// The expander itself: keystrokes in, expansions out.
///
/// Everything before this file is a piece — a tap that reports keystrokes, a matcher that recognises
/// triggers, a renderer that turns a snippet into text, an injector that puts text into another app.
/// This is the wiring, and the wiring is where the thread rules of all four have to be honoured at
/// once.
///
/// ## One serial queue owns the whole pipeline
///
/// `TriggerMatcher` is not `Sendable`, the undo record and the active snippet set are ordinary
/// mutable state, and injection has to happen in the order the keystrokes arrived. All of it is
/// confined to `queue`, a serial `DispatchQueue`, and nothing touches those fields from anywhere
/// else. `KeystrokeMonitor`'s callbacks arrive on the tap thread and do exactly one thing: hand the
/// input to that queue and return. The hop is asynchronous, which is the point — a callback that
/// blocked would park the tap and the window server would disable it.
///
/// The main actor was the alternative and is the wrong home for this. Rendering runs the user's shell
/// commands (seconds, by design), and `TextInjector.paste` blocks while it deep-copies the clipboard,
/// which for a copied image is unbounded work. On the main actor each of those would freeze the UI;
/// worse, every SwiftUI update would then be queued in front of the next keystroke. Off it, the only
/// thing an expansion can hold up is the next expansion — which is exactly the ordering wanted.
///
/// What that costs is that keystrokes typed *during* a slow render queue up behind it and are matched
/// late. The alternative — rendering concurrently — would mean deleting a trigger after the user had
/// typed past it, which corrupts their document rather than merely lagging.
///
/// ## Callbacks are set once, before `start()`
///
/// `onNeedsForm`, `onExpanded` and `onTapFailed` are read from the tap thread and from `queue`, and
/// are plain stored properties with no synchronisation — the same contract `KeystrokeMonitor` sets
/// for its own. Set them at construction and leave them alone. They are called on the main actor,
/// because everything they drive (a panel, the menu's recents, the engine state) lives there.
///
/// ## Concurrency
///
/// `@unchecked Sendable` because the queue is the invariant a compiler cannot see: the matcher and
/// the fields around it are only ever touched inside `queue`, `isPaused` is guarded by its own lock,
/// and the three sub-objects are each safe to reach from any thread by their own documentation.
final class ExpansionEngine: @unchecked Sendable {

    /// A snippet matched, but it has a form that has to be filled in before it can render. The
    /// trigger the user typed is deliberately still on screen: nothing is deleted until an answer
    /// comes back through `completeForm(answers:snippet:match:flow:)`, so cancelling — which is
    /// simply never calling it, see `cancelForm(flow:)` — costs nothing.
    ///
    /// Matching is paused everywhere from the moment this fires until `completeForm`/`cancelForm`
    /// clears it — see `formPending` — and `expand(_:inApp:)` refuses outright for the same span, so
    /// nothing else can expand while whatever this drives is on screen.
    ///
    /// The trailing `String?` is the bundle ID of the app the trigger was typed in, the same one
    /// `completeForm` will eventually inject into: it lets a form panel restore key focus there
    /// before calling back in, which is `completeForm`'s own contract. `nil` when the frontmost app
    /// had no bundle identifier of its own to report.
    ///
    /// The trailing `UUID` names the *flow*: one value per `formPending` false→true transition,
    /// carried unchanged through every hop of a snippet with several form variables and handed back
    /// to `completeForm`/`cancelForm`. Whoever collects the answers has to key them on this rather
    /// than on the `TriggerMatch`, which cannot tell two flows apart at all — two runs of the same
    /// trigger, or two picker expansions (both of which carry an empty `typedText`), are equal
    /// values, and a second run keyed on one would inherit the first's answers and silently skip
    /// the variables they cover.
    var onNeedsForm: (
        @MainActor @Sendable (Snippet, Variable, [FormField], TriggerMatch, String?, UUID) -> Void
    )?

    /// A snippet was injected. Drives the menu's recents list.
    var onExpanded: (@MainActor @Sendable (Snippet) -> Void)?

    /// The event tap was disabled and re-enabling did not help. Expansion is over until something
    /// calls `start()` again — from the main actor, never from this callback.
    var onTapFailed: (@MainActor @Sendable () -> Void)?

    /// How long after an expansion a backspace still means "undo that".
    private static let undoWindow: TimeInterval = 30

    /// How long the target app has to read the clipboard before the user's own is put back. Long
    /// enough for a slow app to have handled the ⌘V, short enough that a copy made straight after an
    /// expansion is not what gets clobbered.
    private static let clipboardRestoreDelay: TimeInterval = 0.5

    /// How much typing history the matcher keeps, spelled here as well so that the count of what the
    /// user typed and the buffer that count describes cannot drift apart.
    private static let matcherBufferLength = 64

    private let monitor = KeystrokeMonitor()
    private let injector = TextInjector()
    private let renderer = ExpansionRenderer()

    /// The one context the matcher and everything below it live on. `userInteractive` because the
    /// work on it is a keystroke away from the user's caret, and it must not queue behind anything.
    private let queue = DispatchQueue(label: "com.fwrds.expansion-engine", qos: .userInteractive)

    // MARK: Confined to `queue`

    private let matcher = TriggerMatcher(maxBufferLength: ExpansionEngine.matcherBufferLength)
    /// The snippets currently matchable, by ID — the same set `matcher` holds, kept as a dictionary
    /// so a match can be turned back into the snippet it came from without a search.
    private var activeSnippets: [UUID: Snippet] = [:]
    private var groups: [SnippetGroup] = []
    private var globals: [GlobalVariable] = []
    private var settings: AppSettings = .default
    /// Bundle IDs the user has paused expansion in from the menu.
    private var pausedBundleIDs: Set<String> = []
    private var frontmostBundleID: String?
    private var pendingUndo: PendingUndo?

    /// How many characters of the matcher's buffer the **user** typed, as opposed to the one this
    /// engine seeded it with. See `seedMatcher(with:)` for why a seed exists at all.
    ///
    /// The seed is a real character in a real buffer, and `TriggerMatch.typedText` is built from that
    /// buffer — so a trigger that reaches back far enough would come back claiming a character the
    /// user never typed, and the deletion that follows would eat the character to the left of their
    /// trigger. This counter is what makes that recognisable.
    private var typedSinceSeed = 0

    /// The app a form's trigger was typed in, remembered across the round trip to the form panel.
    ///
    /// One slot, because one form is asked at a time: the panel is modal to the expansion it belongs
    /// to. A hand-off replaces whatever the last one left here.
    private var formOriginBundleID: String?

    /// Whether a form panel is currently waiting on an answer.
    ///
    /// Set the moment `render(...)` first hands off to `onNeedsForm`, and cleared only once the flow
    /// finally injects or is cancelled — not on the intermediate hops of a snippet with several form
    /// variables, which is why this shares `formOriginBundleID`'s lifetime rather than being reset
    /// on every render. `handle(_:)` reads it exactly the way it reads `isPaused`: while a form is
    /// pending, the trigger's origin app is no longer what is on screen — the form panel is — and
    /// the tap still sees every keystroke, including the ones typed into that panel's own fields. A
    /// keystroke like that completing a trigger would try to delete out of whatever app is
    /// frontmost, which by then is not the one the panel is collecting an answer for, so nothing is
    /// allowed to match until the panel is done.
    ///
    /// `expand(_:inApp:)` reads it too, and refuses. That route never goes through `handle(_:)`, so
    /// the guard above does not cover it, and a menu click landing mid-form would delete out of the
    /// panel exactly as a matched trigger would.
    private var formPending = false

    /// Which form flow `formPending`/`formOriginBundleID` belong to, or `nil` when none is pending.
    ///
    /// Minted on the false→true transition of `formPending` and quoted back by whoever is collecting
    /// the answers — see `onNeedsForm`. It is what lets `render(...)` clear the pending-form
    /// bookkeeping for *that* flow only: an expansion arriving by any other route must leave a
    /// pending form exactly as it found it, and a `completeForm` for a flow that has since been
    /// cancelled must not restart one.
    private var formFlow: UUID?

    /// What the last expansion put on screen, and when — the whole of what undoing it needs.
    private struct PendingUndo {
        /// Characters injected, which is one more than the number of backspaces still owed: the
        /// user's own backspace is not swallowed, so it has already taken one of them.
        let renderedLength: Int
        /// The trigger to put back, exactly as it was typed.
        let typedText: String
        let injectedAt: Date
    }

    // MARK: Reachable from any thread

    /// Guards `paused`, which is written from the main actor and read on every keystroke.
    private let pauseLock = NSLock()
    private var paused = true

    /// Guards `panelSuspended`, written from the main actor and read on every keystroke.
    private let suspensionLock = NSLock()
    private var panelSuspended = false

    /// Whether matching is suspended while the tap stays installed.
    ///
    /// `stop()` sets this before it takes the tap down, which is what it is really for: `stop()`
    /// cannot un-queue a keystroke that the tap thread has already handed to `queue`, and without
    /// this flag that keystroke would expand after the user had asked expansion to stop. Setting it
    /// also empties the matcher, so resuming cannot fire on a buffer from before the pause.
    var isPaused: Bool {
        get { pauseLock.withLock { paused } }
        set {
            pauseLock.withLock { paused = newValue }
            queue.async { [self] in forgetContext() }
        }
    }

    /// Whether one of this app's own panels is on screen, which suspends matching for as long as it
    /// is. Orthogonal to `start()`/`stop()` and to `isPaused`: the tap stays installed, the user's
    /// own switch is untouched, and nothing about the library changes — this is only about *where
    /// the keystrokes are going*.
    ///
    /// The search palette is why this exists. It is a `.nonactivatingPanel`, which is the whole
    /// point of it: F Wrds never becomes the active application, so the document the user was typing
    /// in is still frontmost while they type into the palette's search field. The tap sees those
    /// keystrokes like any others, and a query that happens to be trigger-shaped would match — and
    /// then delete and inject into that document, behind the palette, for something the user only
    /// meant to search for. Worse, it would arm an undo, so a backspace typed in the document
    /// minutes later would take `renderedLength - 1` characters of their real text.
    ///
    /// Setting it either way empties the matcher and drops any armed undo (`forgetContext()`), which
    /// is the same reasoning as `isPaused`: nothing half-typed before a palette opened may complete
    /// after it closes, nothing typed into the palette is in front of the caret, and an undo armed
    /// before a palette session must not still be claimable after one.
    ///
    /// The form panel is *not* driven from here — it has `formPending`, which suspends matching and
    /// carries the rest of the flow's bookkeeping with it. The two are deliberately separate: this
    /// one is a plain "a panel is up", where that one is a whole state machine with a hand-off in
    /// the middle.
    ///
    /// Expanding is not suspended, only *matching* is: `expand(_:inApp:)` never goes through
    /// `handle(_:)`, which is exactly what makes the palette able to expand the snippet it was
    /// opened to find.
    var isPanelSuspended: Bool {
        get { suspensionLock.withLock { panelSuspended } }
        set {
            suspensionLock.withLock { panelSuspended = newValue }
            queue.async { [self] in forgetContext() }
        }
    }

    init() {
        // Set here rather than in `start()`: the monitor reads these from its own thread with no
        // synchronisation, so assigning one while a tap is live would race it.
        monitor.onKeyInput = { [weak self] input in
            guard let self else { return }
            queue.async { self.handle(input) }
        }
        monitor.onBufferInvalidatingEvent = { [weak self] in
            guard let self else { return }
            queue.async { self.forgetContext() }
        }
        monitor.onTapDisabled = { [weak self] in
            guard let self else { return }
            // Deliberately not a `start()` from here: `start()` on a dead tap calls `stop()`, and
            // `stop()` waits for this very thread to unwind. Whoever handles this on the main actor
            // decides whether to retry.
            let callback = onTapFailed
            Task { @MainActor in callback?() }
        }
    }

    deinit {
        // A running monitor keeps itself alive through its thread, so this is the only thing that
        // could ever release it. Unreachable while the app owns one engine for its lifetime, which is
        // why it is one line rather than a shutdown protocol.
        monitor.stop()
    }

    // MARK: Lifecycle

    /// Installs the tap and starts expanding. Call from the main actor.
    ///
    /// - Returns: `false` when the tap could not be installed, which in practice means Input
    ///   Monitoring has not been granted — see `KeystrokeMonitor.start()`. Nothing is left running in
    ///   that case, and calling this again is the retry.
    @discardableResult
    func start() -> Bool {
        guard monitor.start() else { return false }
        isPaused = false
        return true
    }

    /// Takes the tap down and stops expanding. Call from the main actor. Safe to call twice.
    func stop() {
        // Before the tap goes, so that anything already queued from it finds matching switched off.
        isPaused = true
        monitor.stop()
    }

    // MARK: Keystrokes

    /// Runs on `queue`.
    private func handle(_ input: KeyInput) {
        guard !isPaused, !isPanelSuspended, !formPending else {
            // Nothing typed while paused — or while one of this app's own panels is up, whether it
            // is the search palette waiting on a query or a form panel waiting on an answer — is in
            // front of the caret as far as the matcher is concerned: resuming must not complete a
            // trigger that was half-typed before the pause, or half-typed into a panel instead of
            // whatever document the trigger actually came from.
            forgetContext()
            return
        }

        if input == .backspace, let undo = pendingUndo, settings.undoOnBackspace,
           Date().timeIntervalSince(undo.injectedAt) < Self.undoWindow {
            pendingUndo = nil
            performUndo(undo)
            return
        }
        // Any other keystroke closes the offer. Undo is for the moment straight after an expansion
        // that was not wanted, not for a backspace three words later.
        pendingUndo = nil

        countTyped(input)
        guard let match = matcher.process(input) else { return }
        // A match empties the matcher's buffer, and with it whatever seed was at the front. That
        // happened inside the call above whether or not the match is used, so the count is cleared
        // here rather than only on the path that expands — and a discarded match below therefore
        // still costs the buffer, which is the honest outcome: those characters have been matched
        // once and must not be able to match again.
        let typedLength = typedSinceSeed
        typedSinceSeed = 0
        // A trigger longer than the user has typed since the seed has swallowed the seeded character
        // — `:addr` expanding to a sentence ending in `.`, then `sig` completing a `.sig` trigger.
        // Expanding it would delete one character more than the user typed, taking the full stop off
        // the end of the expansion. It is not a match; it is the seed being read as typing.
        //
        // The cost is a trigger that does not fire when its opening characters were put on screen by
        // the expansion before it, and that is the right way round: a missed expansion is retyped in
        // a second, where the other outcome quietly removes a character of the user's document.
        guard match.typedText.count <= typedLength else { return }
        guard let snippet = activeSnippets[match.snippetID] else { return }
        render(snippet, match: match, answers: [:], inApp: frontmostBundleID)
    }

    /// Tracks how much of the matcher's buffer is the user's own typing. Runs on `queue`.
    private func countTyped(_ input: KeyInput) {
        switch input {
        case .character:
            // Clamped to the buffer's own length: past that the seed has rolled off the front, every
            // character in the buffer is typed, and a bigger number would describe nothing.
            typedSinceSeed = min(typedSinceSeed + 1, Self.matcherBufferLength)
        case .backspace:
            // At zero the backspace is taking the seeded character off instead — which leaves the
            // buffer with nothing typed in it either way.
            typedSinceSeed = max(typedSinceSeed - 1, 0)
        case .reset:
            typedSinceSeed = 0
        }
    }

    /// Puts the trigger back where the expansion is. Runs on `queue`.
    ///
    /// The tap is listen-only, so the backspace that asked for this reached the app as well and has
    /// already taken one character off the expansion; the rest are owed here.
    ///
    /// Nothing has to suppress matching while this replays. The queue is serial and this call holds
    /// it, so no keystroke can be processed in the middle of it — and everything `TextInjector` posts
    /// carries the mark that makes `KeystrokeMonitor` drop it, so the replay is not seen as typing in
    /// the first place. What does matter is the buffer afterwards: the trigger is on screen again, and
    /// a matcher that held it would complete it on the spot and expand for a second time.
    private func performUndo(_ undo: PendingUndo) {
        injector.deleteCharacters(undo.renderedLength - 1)
        injector.typeText(undo.typedText)
        // Seeded with the last character of the trigger for the same reason an expansion is: the
        // caret now follows text this app put there, and a matcher that thought it followed nothing
        // would read the start of its empty buffer as a word delimiter and let a `wordBoundary`
        // trigger fire in the middle of the restored word.
        seedMatcher(with: undo.typedText.last)
    }

    /// Drops everything that was true about the caret's surroundings. Runs on `queue`.
    ///
    /// All three, and the third is not incidental: an armed undo is a claim about text this app put
    /// on screen a moment ago and about where the caret still is relative to it. Every caller here
    /// is a moment where that claim stops being safe to hold — the app in front changed, expansion
    /// was switched off, a panel took the keyboard — and a backspace arriving after one of those
    /// would otherwise delete `renderedLength - 1` characters of whatever the user is typing now.
    private func forgetContext() {
        matcher.resetBuffer()
        typedSinceSeed = 0
        pendingUndo = nil
    }

    // MARK: Expanding

    /// Expands `snippet` where the caret is, with nothing to take back — the menu's route in.
    ///
    /// Works whether or not the engine is running: injection needs Accessibility, not the tap, and a
    /// snippet the user picked by hand is not something a paused expander should refuse — nor is it
    /// something the search palette's own suspension should refuse, since expanding is exactly what
    /// the palette was opened to do. A form is still a form, so this can hand off to `onNeedsForm`
    /// exactly as a typed trigger does. The one thing it will not do is start a second expansion
    /// while a form panel is already waiting on an answer; see `expand(_:inApp:)`.
    ///
    /// Where "where the caret is" ends up is the caller's timing: the app in front *when this runs*
    /// is the app that gets the text — read fresh from `frontmostBundleID` at that moment, not at the
    /// moment this was called — and the menu's own close animation is why `AppModel` waits before
    /// calling it. Switching apps inside that window would land the expansion in the new one.
    ///
    /// See `expand(_:inApp:)` for the alternative a caller can reach for when that dynamic read is
    /// the wrong answer.
    func expand(_ snippet: Snippet) {
        expand(snippet, inApp: nil)
    }

    /// Expands `snippet` as if its trigger had just been typed in `bundleID` — or, when `bundleID` is
    /// `nil`, exactly what `expand(_:)` does: read whatever this engine currently believes is
    /// frontmost at the moment it actually runs.
    ///
    /// The explicit `bundleID` is for a caller that already knows which app the choice belongs to and
    /// would rather not trust that this engine's own tracked frontmost app is still the same one by
    /// the time the queued render runs. The picker is exactly that caller: it captures the frontmost
    /// bundle ID before showing its panel, and showing a panel — even a non-activating one — is a
    /// second window server round trip between "the user asked for this" and "the answer is ready to
    /// inject" that `expand(_:)`'s dynamic read has no reason to survive by luck.
    ///
    /// **Refused outright while a form panel is waiting on an answer**, with no side effect and
    /// nothing reported. The form flow owns the caret's surroundings until it finishes: the trigger
    /// that started it is still on screen waiting to be replaced, the panel holds key focus, and an
    /// expansion squeezed in here would inject into the panel and leave the flow pointing at an app
    /// it is no longer coming back to. Nothing is logged because there is nothing wrong to report —
    /// it is a click on a menu that happened to still be reachable, and the panel in front of the
    /// user is the honest answer to it.
    func expand(_ snippet: Snippet, inApp bundleID: String?) {
        queue.async { [self] in
            guard !formPending else { return }
            render(snippet, match: TriggerMatch(snippetID: snippet.id, typedText: ""), answers: [:],
                   inApp: bundleID ?? frontmostBundleID)
        }
    }

    /// Renders `snippet` with the answers given and injects the result, or asks for the answers it is
    /// still missing.
    ///
    /// Passing the answers back in rather than holding them here is what keeps the form flow
    /// restartable: a snippet with two form variables comes back through `onNeedsForm` a second time,
    /// and whoever is collecting them carries the first set forward.
    ///
    /// ## What the caller has to guarantee
    ///
    /// This deletes `match.typedText.count` characters backwards **from wherever the caret is**, and
    /// there is nothing it can check first — this app cannot read the document. So:
    ///
    /// - **Put focus back in the app the trigger was typed in before calling.** A form panel takes
    ///   key focus, which means F Wrds became the frontmost app somewhere in the middle of this flow;
    ///   calling from there would delete out of the panel, or out of whatever else has focus.
    /// - **Only call while the trigger is still on screen with the caret directly after it.** If the
    ///   user typed on, moved the caret or switched documents while the form was open, the deletion
    ///   would take their text instead. Cancel in that case — call `cancelForm()` instead of this,
    ///   so the engine's own pending-form bookkeeping is cleared and matching resumes elsewhere.
    ///   Nothing has been deleted yet, so cancelling always costs nothing.
    ///
    /// The one thing this does not need told is the injection mode's app: the bundle ID the trigger
    /// was typed in was captured at hand-off and is what the per-app override is read from, rather
    /// than whatever happens to be frontmost when the answers arrive.
    ///
    /// Matching everywhere else stays paused (`formPending`) from the moment `onNeedsForm` first
    /// fired until this call — or `cancelForm(flow:)` — clears it. A snippet with more than one form
    /// variable calls back into `onNeedsForm` again from inside this same render, still paused and
    /// still under the same `flow`, so there is no window in between for a second trigger to fire.
    ///
    /// - Parameter flow: the flow token `onNeedsForm` handed out. A call quoting anything else is
    ///   answering a flow that has already finished or been cancelled and is dropped: the trigger it
    ///   was asked about is long gone from the screen, so rendering it now would delete live text.
    func completeForm(answers: [String: String], snippet: Snippet, match: TriggerMatch, flow: UUID) {
        queue.async { [self] in
            guard flow == formFlow else { return }
            let origin = formOriginBundleID ?? frontmostBundleID
            formOriginBundleID = nil
            render(snippet, match: match, answers: answers, inApp: origin, continuing: flow)
        }
    }

    /// Abandons a pending form without rendering anything — Escape, a click outside the panel, or
    /// the origin app failing to come back to the front in time.
    ///
    /// `render(...)` has deleted nothing by the time a form is asked for, so there is nothing here
    /// to undo; this only clears the bookkeeping `render(...)` left behind at the `needsForm` hop —
    /// `formOriginBundleID`, `formPending` and `formFlow` — so a later trigger does not inherit an
    /// app it was never typed in, and matching resumes.
    ///
    /// - Parameter flow: as for `completeForm`, the token that flow was handed. A cancel for a flow
    ///   that is already over clears nothing, so it cannot tear down a newer one that has started
    ///   since.
    func cancelForm(flow: UUID) {
        queue.async { [self] in
            guard flow == formFlow else { return }
            formOriginBundleID = nil
            formPending = false
            formFlow = nil
        }
    }

    /// Runs on `queue`.
    ///
    /// - Parameter flow: the form flow this render belongs to, or `nil` when it belongs to none —
    ///   a typed trigger or a menu/picker expansion, neither of which may touch a pending form's
    ///   bookkeeping on its way past.
    private func render(_ snippet: Snippet, match: TriggerMatch, answers: [String: String],
                        inApp bundleID: String?, continuing flow: UUID? = nil) {
        let context = makeContext(regexCaptures: match.regexCaptures, formAnswers: answers)
        switch renderer.render(snippet: snippet, transform: match.caseTransform, context: context) {
        case .rendered(let expansion):
            // Only the flow that set these may clear them. Clearing unconditionally was the bug:
            // an expansion that reached here by another route — the menu, while a form panel was
            // already up — would drop `formPending` with the panel still on screen and leave
            // `formOriginBundleID` pointing at an app the abandoned flow would never come back to.
            if let flow, flow == formFlow {
                formPending = false
                formFlow = nil
                formOriginBundleID = nil
            }
            inject(expansion, of: snippet, replacing: match, inApp: bundleID)
        case .needsForm(let variable, let fields):
            // A fresh flow gets a fresh token; the next variable of a flow already under way keeps
            // the one it started with, so whoever is accumulating answers can tell "the same form,
            // one field further on" from "a second run of the same snippet".
            let flow = flow ?? UUID()
            // Held for the eventual `completeForm`: by the time the answers come back the frontmost
            // app is the form panel's, and reading the injection mode from that would be reading it
            // for F Wrds rather than for the app the user is typing in.
            formPending = true
            formFlow = flow
            formOriginBundleID = bundleID
            let callback = onNeedsForm
            Task { @MainActor in callback?(snippet, variable, fields, match, bundleID, flow) }
        }
    }

    /// Takes back the trigger, puts the expansion in its place, and leaves the caret where the
    /// snippet asked for it. Runs on `queue`.
    private func inject(_ expansion: RenderedExpansion, of snippet: Snippet,
                        replacing match: TriggerMatch, inApp bundleID: String?) {
        injector.deleteCharacters(match.typedText.count)

        if !expansion.text.isEmpty {
            switch injectionMode(inApp: bundleID) {
            case .paste:
                injector.paste(expansion.text, restoreClipboardAfter: Self.clipboardRestoreDelay)
            case .typed:
                injector.typeText(expansion.text)
            }
        }
        if let offset = expansion.cursorOffsetFromEnd, offset > 0 {
            injector.pressArrowLeft(times: offset)
        }

        seedMatcher(with: Self.characterLeftOfCaret(after: expansion))
        armUndo(for: expansion, replacing: match)

        let callback = onExpanded
        Task { @MainActor in callback?(snippet) }
    }

    /// How an expansion should reach `bundleID`. Runs on `queue`.
    private func injectionMode(inApp bundleID: String?) -> AppSettings.InjectionMode {
        bundleID.flatMap { settings.perAppInjectionOverrides[$0] } ?? settings.defaultInjectionMode
    }

    /// Puts the character the caret now sits after into the matcher, and starts counting the typing
    /// that follows it. Runs on `queue`.
    ///
    /// `TriggerMatcher` empties its buffer on a match and counts the start of the buffer as a word
    /// delimiter — it has to, or a trigger would stop firing once the buffer rolled over. Together
    /// those mean that straight after an expansion the matcher believes the caret follows a
    /// delimiter, and a `wordBoundary` trigger typed immediately after one would fire in the middle
    /// of a word. Seeding the buffer with the character genuinely to the left of the caret is what
    /// makes the boundary test tell the truth, and it is the one thing this app knows for certain
    /// about the document it cannot read.
    ///
    /// The seed is not free, which is what `typedSinceSeed` is for: it is a real character in the
    /// buffer, and a trigger that reaches back over it would report a `typedText` one character
    /// longer than the user typed. `handle(_:)` discards those.
    private func seedMatcher(with character: Character?) {
        matcher.resetBuffer()
        typedSinceSeed = 0
        guard let character else { return }
        // A one-character trigger could complete on this seed. It was not typed, so the match is
        // dropped — and the buffer it emptied is the same empty buffer this started from.
        _ = matcher.process(.character(character))
    }

    /// The character immediately left of the caret once `expansion` has landed, or `nil` when there
    /// is nothing this app can say about it.
    ///
    /// A `$|$` cursor hint moves the caret back into the expansion, so the character it now follows
    /// is not the last one. When the hint puts the caret before *all* of the injected text there is
    /// no such character — what precedes it is whatever was in the document before the trigger, which
    /// this app no longer knows.
    private static func characterLeftOfCaret(after expansion: RenderedExpansion) -> Character? {
        let characters = Array(expansion.text)
        let index = characters.count - (expansion.cursorOffsetFromEnd ?? 0) - 1
        guard characters.indices.contains(index) else { return nil }
        return characters[index]
    }

    /// Remembers what to undo, when there is something undoable to remember. Runs on `queue`.
    ///
    /// Two expansions are deliberately left un-undoable. One with nothing typed in front of it came
    /// from the menu rather than from a trigger, so a backspace straight afterwards is the user
    /// editing, not correcting. One that moved the caret with `$|$` has the caret somewhere inside
    /// what was injected, and deleting `renderedLength - 1` characters backwards from there would eat
    /// the document either side of it — a wrong undo is worse than no undo.
    ///
    /// What is left is an accepted risk: arming this trusts that the injection landed as counted, and
    /// nothing can confirm that from outside the app. An app that has rebound ⌘V, or that swallowed
    /// the paste, leaves an undo armed for text that was never inserted, and the user's next
    /// backspace deletes that much of their own document instead. The 30-second window and the
    /// next-keystroke-only rule are what keep the exposure to the moment right after an expansion the
    /// user watched fail.
    private func armUndo(for expansion: RenderedExpansion, replacing match: TriggerMatch) {
        guard !expansion.text.isEmpty, !match.typedText.isEmpty,
              (expansion.cursorOffsetFromEnd ?? 0) == 0 else {
            pendingUndo = nil
            return
        }
        pendingUndo = PendingUndo(renderedLength: expansion.text.count, typedText: match.typedText,
                                  injectedAt: Date())
    }

    /// The production `RenderContext` — the real clock, the real clipboard, the real shell.
    ///
    /// Built per render rather than held, because two of its fields are the match's own: the regex
    /// captures that fired it and the form answers that came back for it.
    private func makeContext(regexCaptures: [String: String],
                             formAnswers: [String: String]) -> RenderContext {
        // The pasteboard belongs to `TextInjector`, which serialises every touch of it onto one
        // queue; reading it here directly would break that and race an expansion's clipboard restore.
        let injector = self.injector
        return RenderContext(
            now: Date.init,
            clipboard: { injector.clipboardText() },
            runShell: { command, timeoutSeconds in try ShellRunner.run(command, timeout: timeoutSeconds) },
            globals: globals,
            regexCaptures: regexCaptures,
            formAnswers: formAnswers
        )
    }
}

/// The matchable set, and everything that changes it.
///
/// An extension rather than more of the class body above, and deliberately in this same file: the
/// type was over SwiftLint's body ceiling, and everything here touches fields that are `private`
/// precisely because "only ever on `queue`" is the invariant holding this type together. A split
/// into another file would have had to widen those to `internal` to buy the same line count, which
/// is the one thing not worth trading for it.
extension ExpansionEngine {

    /// Replaces the library the engine matches against, and rebuilds the active set from it.
    func updateLibrary(groups: [SnippetGroup], globals: [GlobalVariable]) {
        queue.async { [self] in
            self.groups = groups
            self.globals = globals
            applyActiveSnippets()
        }
    }

    /// Replaces the settings the engine reads — injection mode, and whether backspace undoes.
    func updateSettings(_ settings: AppSettings) {
        queue.async { [self] in self.settings = settings }
    }

    /// Replaces the set of apps the user has paused expansion in, and rebuilds the active set.
    func setPausedApps(_ bundleIDs: Set<String>) {
        queue.async { [self] in
            pausedBundleIDs = bundleIDs
            applyActiveSnippets()
        }
    }

    /// Recomputes what is matchable now that `bundleID` is the app in front.
    ///
    /// Called on every app switch, which is also why it forgets the typing buffer: the caret is in a
    /// different document, and characters typed in the last app are not in front of it.
    ///
    /// The switch and the typing race, and nothing can order them: a key pressed in the new app
    /// before this lands is matched against the old app's set. The window is the notification's own
    /// latency and the loser is at worst one keystroke, which is the same keystroke a trigger would
    /// need several of.
    func rebuildActiveSnippets(frontmostBundleID bundleID: String?) {
        queue.async { [self] in
            frontmostBundleID = bundleID
            applyActiveSnippets()
        }
    }

    /// Runs on `queue`.
    private func applyActiveSnippets() {
        forgetContext()
        let snippets = Self.matchable(in: groups, forApp: frontmostBundleID, pausedApps: pausedBundleIDs)
        matcher.setSnippets(snippets)
        // A library with two snippets sharing an ID is not something this can fix; the first wins,
        // which is the same tie-break the matcher applies.
        activeSnippets = Dictionary(snippets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The snippets that may fire in `bundleID`, honouring every switch that can turn one off.
    ///
    /// An unknown app — `bundleID` is `nil` because nothing is active, or because the frontmost app
    /// has no bundle identifier — suppresses any group limited to named apps. Expanding a
    /// work-only group into an unknown window is worse than not expanding.
    private static func matchable(in groups: [SnippetGroup], forApp bundleID: String?,
                                  pausedApps: Set<String>) -> [Snippet] {
        if let bundleID, pausedApps.contains(bundleID) { return [] }
        return groups.filter { group in
            guard group.isEnabled else { return false }
            if !group.onlyInApps.isEmpty {
                guard let bundleID, group.onlyInApps.contains(bundleID) else { return false }
            }
            if let bundleID, group.neverInApps.contains(bundleID) { return false }
            return true
        }
        .flatMap { $0.snippets.filter(\.isEnabled) }
    }
}
