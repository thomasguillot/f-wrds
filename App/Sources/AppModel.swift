import AppKit
import Foundation
import Observation
import SwiftUI
import WrdsKit

/// Whether expansion is happening, and when it is not, why not.
enum EngineState: Equatable {
    /// The tap is installed and triggers expand.
    case running
    /// Deliberately off — the user's toggle, or nothing trustworthy to expand from.
    case paused
    /// Accessibility or Input Monitoring has not been granted.
    case permissionsMissing
    /// The grants are in place but the event tap could not be installed or stayed disabled.
    case tapFailed
}

/// The one object the views talk to: it owns the two stores and the expansion engine, mirrors their
/// state as something observable, and is the only place that writes to any of them.
///
/// Loading is deliberately non-fatal. Both stores refuse to write until a `load()` has succeeded, so
/// a failure here is surfaced as text and the matching editing surface is switched off rather than
/// letting the app overwrite a file it could not read.
///
/// The engine follows from that rather than being driven directly: `engineState` is recomputed from
/// the stores, the settings and the two permissions, and starting or stopping the tap is what makes
/// the world match it. Nothing else may start it — see `refreshEngineState()`.
@MainActor
@Observable
final class AppModel {
    /// `~/Library/Application Support/FWrds` — the single spelling of the app's data directory.
    static let supportDirectory = URL.applicationSupportDirectory
        .appending(path: "FWrds", directoryHint: .isDirectory)

    /// How many snippets the menu offers under "Recent".
    private static let recentLimit = 5

    /// How long to wait after a menu click before injecting, so the menu is gone and the app the user
    /// was typing in is in front again. The menu closes on the click; this is the window server
    /// catching up with it.
    ///
    /// `PickerPanel.menuCloseDelay` uses this same value for the same reason, when the picker is
    /// opened from the menu's "Open Picker" item rather than its hotkey — see the note there for why
    /// that path needs it and the hotkey path does not.
    private static let menuCloseDelay: TimeInterval = 0.2

    /// `HotKeyCenter` IDs for the two hotkeys this model registers. Scoped to this app's own
    /// registrations only — see `HotKeyCenter.signature` — so these just have to be distinct from
    /// each other. Not `private`: `AppModel+Picker.swift` registers against them.
    static let pickerHotKeyID: UInt32 = 1
    static let pauseHotKeyID: UInt32 = 2

    private(set) var groups: [SnippetGroup] = []
    private(set) var globals: [GlobalVariable] = []
    private(set) var settings: AppSettings = .default
    private(set) var engineState: EngineState = .paused

    /// The snippets expanded this session, newest first, capped at `recentLimit`.
    ///
    /// Session-only on purpose: a recents list that survived a restart would be a record of what the
    /// user typed, kept on disk by an app that has no other reason to keep one.
    private(set) var recentSnippetIDs: [UUID] = []

    /// Bundle IDs the user has paused expansion in from the menu. Session-only: pausing in an app is
    /// a "not now", and a pause that outlived a restart would be a setting nobody remembers making.
    private(set) var pausedAppBundleIDs: Set<String> = []

    /// The last app that was in front that was not F Wrds itself, for the menu to name.
    ///
    /// F Wrds is skipped because clicking the menu bar can make it the active app, and a menu that
    /// offered to pause expansion "in F Wrds" would be offering it about itself rather than about
    /// whatever the user was typing in a moment ago.
    private(set) var frontmostAppBundleID: String?
    private(set) var frontmostAppName: String?

    /// Why the window server refused to register `settings.pickerHotKey` and/or `pauseHotKey`, for
    /// the menu's status line — a separate slot from `storeFailure` because a hotkey conflict is not
    /// a store problem and outranking one with the other would bury whichever happened second. `nil`
    /// once both are registered, or unset. Not `private(set)`: `AppModel+Picker.swift`'s
    /// `reregisterHotKeys()` is what writes it.
    var hotKeyFailure: String?

    /// The most recent thing a store could not do — read a file, or save one — written for the user
    /// and shown by `StoreFailureBanner`. `nil` when there is nothing to say.
    ///
    /// One slot, so a save failure replaces a load failure and vice versa: the newest problem is the
    /// one worth showing, and a load failure that still applies is re-reported by the next `load()`.
    /// Settable so the banner's Dismiss can clear it.
    var storeFailure: String?

    /// A form panel submission that could not be delivered — the origin app had quit, or did not
    /// reactivate before `FormPanelController`'s timeout — shown in the menu the way `hotKeyFailure`
    /// is.
    ///
    /// Unlike `hotKeyFailure`, which describes an ongoing condition that clears once
    /// `reregisterHotKeys()` fixes it, this describes one past event with nothing left to fix, so it
    /// clears itself a few seconds after being set rather than lingering until something unrelated
    /// happens to overwrite it — see `AppModel+Forms.swift`'s `showFormFailure(_:)`, which is also
    /// why, like `hotKeyFailure`, this is not `private(set)`. `formFailureToken` is what stops an old
    /// failure's timer from clearing a newer one it raced; nothing outside that file needs it.
    var formFailure: String?
    var formFailureToken: UUID?

    /// How many settings writes have failed. Nothing displays this number — controls read it through
    /// `binding(_:)`, and that read is the whole point.
    ///
    /// Observation does not notify observers when a property is assigned a value equal to the one it
    /// already holds (verified on Swift 6.3). A failed write deliberately leaves `settings` as it
    /// was, so re-publishing it would tell SwiftUI nothing and the control would stay drawn in the
    /// position the user clicked rather than the one that is on disk. This counter is the thing that
    /// does change, which is what forces the control to be rebuilt from the persisted value.
    private(set) var saveFailures = 0

    /// Mirrors of each store's `hasLoadedSuccessfully`, kept as stored properties so that a view
    /// which only reads these still re-renders when a load changes them.
    private(set) var canEditSnippets = false
    private(set) var canEditSettings = false

    /// Which group's snippets `SnippetListView` shows, and which of those snippets
    /// `SnippetEditorView` is open on. `nil` shows a placeholder rather than picking something on
    /// the user's behalf.
    ///
    /// Unlike `groups`/`globals`, plainly settable rather than routed through a seam: selection is
    /// not persisted and has no failure mode, so there is nothing a second file changing it directly
    /// could get wrong. `AppModel+Library.swift`'s selection functions are still the intended way in.
    var selectedGroupID: UUID?
    var selectedSnippetID: UUID?

    /// Whether the sidebar's fixed "Global Variables" row is the current selection. Takes priority
    /// over `selectedGroupID` in the view layer — the manager window shows `GlobalsEditorView`
    /// instead of the group/snippet columns while this is true.
    var isGlobalsSelected = false

    /// A snippet just created by `createSnippet(in:)`, consumed once by `SnippetEditorView` to focus
    /// its "add trigger" field the moment the editor appears — the detail-pane equivalent of the
    /// sidebar's "new item opens ready to rename".
    var pendingTriggerFocusSnippetID: UUID?

    /// A group or snippet awaiting the confirmation `MainWindowView` shows before either is actually
    /// deleted. Every delete affordance — a context menu's Delete, ⌘⌫ — calls `requestDelete…`
    /// rather than deleting outright; only `confirmPendingDeletion()` does the deleting. Settable so
    /// the dialog's Cancel, and dismissing it any other way, can clear it.
    enum PendingDeletion: Identifiable, Equatable {
        case group(UUID)
        case snippet(UUID)
        var id: UUID {
            switch self {
            case .group(let id): return id
            case .snippet(let id): return id
            }
        }
    }
    var pendingDeletion: PendingDeletion?

    private let snippetStore: SnippetStore
    private let settingsStore: SettingsStore

    /// The expander. Owned here because everything that decides whether it should be running —
    /// the stores, the settings, the frontmost app — is owned here.
    ///
    /// Not `private`: `AppModel+Picker.swift` reaches it to route picker expansions through the same
    /// `expand(_:inApp:)` the menu uses, the same way `AppModel+Library.swift` already reaches
    /// `groups`/`globals` across the file split. `let` still keeps it from being reassigned from
    /// anywhere outside this file.
    let engine = ExpansionEngine()

    /// The global hotkeys. Registration does not need Accessibility or Input Monitoring — see
    /// `HotKeyCenter` — so unlike the engine there is no permission gate before this is used. Not
    /// `private`, for the reason given at `engine` above.
    let hotKeyCenter = HotKeyCenter()

    /// The search palette. One instance for the app's lifetime — see `PickerPanel`'s own doc comment
    /// for why it is shown and hidden rather than rebuilt. Not `private`, for the reason given at
    /// `engine` above.
    let pickerPanel = PickerPanel()

    /// The form panel a form snippet's trigger pops open. One instance for the app's lifetime, for
    /// the same reason as `pickerPanel` — see `FormPanelController`'s own doc comment. Not `private`,
    /// for the reason given at `engine` above: `AppModel+Forms.swift`'s `formNeeded(...)` reaches it.
    let formPanel = FormPanelController()

    /// Whether `activate()` has run. The tap is not installed before it: `AppModel` is built while
    /// the process is still launching, and asking the window server for an event tap at that point
    /// would put a permission prompt in front of someone who has not yet seen the app.
    ///
    /// `private(set)`, not plain `private`: `AppModel+Picker.swift`'s `reregisterHotKeys()` reads it
    /// to gate the same way `refreshEngineState()` does, but only ever reads — both writes
    /// (`activate()`/`deactivate()`) stay in this file, same shape as `groups`/`globals`.
    private(set) var isActivated = false

    /// - Parameter directory: where `store.json` and `settings.json` live. Defaults to the real
    ///   support directory; tests and previews pass a temporary one.
    init(directory: URL = AppModel.supportDirectory) {
        snippetStore = SnippetStore(directory: directory)
        settingsStore = SettingsStore(directory: directory)

        // Before `load()`, because loading is what first tells the engine what to match against.
        engine.onExpanded = { [weak self] snippet in self?.recordExpansion(of: snippet) }
        engine.onNeedsForm = { [weak self] snippet, variable, fields, match, originBundleID, flow in
            self?.formNeeded(FormPanelController.FormRequest(
                snippet: snippet, variable: variable, fields: fields, match: match,
                originBundleID: originBundleID, flow: flow))
        }
        engine.onTapFailed = { [weak self] in self?.engineState = .tapFailed }
        // The palette becomes key without activating this app — which is what makes it usable at
        // all, and also what would otherwise let a trigger-shaped search query match and expand into
        // the document still sitting frontmost behind it. See `ExpansionEngine.isPanelSuspended`.
        pickerPanel.onVisibilityChanged = { [weak self] isVisible in
            self?.engine.isPanelSuspended = isVisible
        }

        load()
    }

    /// Reads both stores, replacing everything this model publishes. Safe to call again: a store
    /// that failed last time gets another chance, and one that succeeds re-arms its own writes.
    func load() {
        var problems: [String] = []

        do {
            try snippetStore.load()
            groups = snippetStore.groups
            globals = snippetStore.globals
            if snippetStore.didPreserveCorruptFile {
                problems.append(String(localized: """
                    F Wrds couldn't read your snippet library. The old file is saved as \
                    store.json.corrupt, and F Wrds started again with the example snippets.
                    """))
            }
        } catch {
            // Whatever a previous load put here describes a file this one could not read. Showing it
            // under a "couldn't be read" banner would be a lie, and a retry that fails would leave
            // the window looking like it had worked.
            groups = []
            globals = []
            problems.append(String(localized: """
                F Wrds couldn't load your snippets: \(Self.describe(error)). The file is untouched. \
                Editing is off so nothing overwrites it.
                """))
        }

        do {
            try settingsStore.load()
            settings = settingsStore.settings
            if settingsStore.didPreserveCorruptFile {
                problems.append(String(localized: """
                    F Wrds couldn't read your settings. The old file is saved as \
                    settings.json.corrupt and the defaults are back.
                    """))
            }
        } catch {
            problems.append(String(localized: """
                F Wrds couldn't load your settings: \(Self.describe(error)). The file is untouched \
                and the default settings are in use for now.
                """))
        }

        canEditSnippets = snippetStore.hasLoadedSuccessfully
        // A load can drop the group or snippet that was selected — including on the very first
        // load, when nothing has been selected yet — so the panes are never left pointing at
        // something that no longer exists.
        if selectedGroupID == nil || !groups.contains(where: { $0.id == selectedGroupID }) {
            selectedGroupID = groups.first?.id
            selectedSnippetID = nil
        }
        if let snippetID = selectedSnippetID, snippet(id: snippetID) == nil {
            selectedSnippetID = nil
        }
        canEditSettings = settingsStore.hasLoadedSuccessfully
        engine.updateSettings(settings)
        pushLibrary()
        refreshEngineState()
        storeFailure = problems.isEmpty ? nil : problems.joined(separator: "\n\n")
    }

    /// Persists `settings` and re-applies everything derived from them.
    ///
    /// The store writes to disk before it adopts the new value, so a failed write leaves both the
    /// file and this model showing what is actually saved; `saveFailures` is what makes the control
    /// the user just clicked redraw itself from that.
    func update(_ settings: AppSettings) {
        do {
            try settingsStore.update(settings)
            self.settings = settingsStore.settings
            engine.updateSettings(self.settings)
            refreshEngineState()
            applyDockIconPolicy()
            reregisterHotKeys()
        } catch {
            saveFailures += 1
            storeFailure = String(localized: "Your settings couldn't be saved: \(Self.describe(error)).")
        }
    }

    /// A binding onto one setting that writes the whole file whenever it changes.
    ///
    /// Settings go through `update(_:)` rather than being mutated in place, which is why `settings`
    /// is read-only from outside and views ask for a binding instead of using `@Bindable`.
    func binding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: {
                // Reading `saveFailures` inside the getter is what subscribes the control drawing
                // this setting to write failures — see the note on that property.
                _ = self.saveFailures
                return self.settings[keyPath: keyPath]
            },
            set: { newValue in
                var updated = self.settings
                updated[keyPath: keyPath] = newValue
                self.update(updated)
            }
        )
    }

    /// Whether any of the app's own windows (manager, settings, import, setup, about) is on screen.
    /// Kept current by `AppDelegate`'s window observers.
    var hasVisibleAppWindow = false

    /// An Espanso import waiting on `MainWindowView`'s preview sheet. See `startEspansoImport()`.
    var pendingEspansoImport: PendingEspansoImport?
    /// What the last confirmed import added, for `MainWindowView`'s report sheet.
    var espansoImportSummary: EspansoImportSummary?

    // MARK: The snippet library
    //
    // Group/snippet/global CRUD, selection, and the pinned/recent menu lists live in
    // `AppModel+Library.swift` — this class was over SwiftLint's type-body ceiling with them
    // inlined. `persistLibrary(groups:globals:)` stays here because it writes `groups`/`globals`
    // directly: they are `private(set)` so that file's `mutateLibrary(_:)` is the only path in.

    /// Persists a working copy of the library to `store.json` and pushes it to the engine, or
    /// reports why it could not.
    ///
    /// Disk first, the same shape as `update(_:)` for settings: `groups`/`globals` only advance once
    /// the write actually lands, so a failed save leaves every view showing what is really on disk
    /// rather than an edit that never reached it.
    @discardableResult
    func persistLibrary(groups: [SnippetGroup], globals: [GlobalVariable]) -> Bool {
        do {
            try snippetStore.replaceAll(groups: groups, globals: globals)
            self.groups = groups
            self.globals = globals
            pushLibrary()
            return true
        } catch {
            storeFailure = String(localized: "Your snippets couldn't be saved: \(Self.describe(error)).")
            return false
        }
    }

    /// Replaces the whole configuration with `bundle` — the only way `groups`/`globals`/`settings`
    /// all change together, and the counterpart to `BackupSettingsView`'s export. The library lands
    /// first, then settings, so that a settings-store failure after the library already landed still
    /// leaves both stores individually consistent (the library is exactly the backup's; settings are
    /// whatever they were a moment ago) rather than a file half-overwritten by each. Either write can
    /// fail on its own — both `persistLibrary` and `update(_:)` already report through
    /// `storeFailure`, and both refuse outright via `StoreError.notLoaded` if their store never
    /// loaded successfully — so a restore that fails partway is safe to inspect and retry rather than
    /// silently corrupt.
    ///
    /// - Returns: whether *both* halves actually landed. `persistLibrary` already answers this for
    ///   itself; `update(_:)` does not return anything (every other settings write ignores this, and
    ///   widening that signature app-wide for restore's sake alone was not worth it), so its half is
    ///   inferred instead: `update(_:)` only ever adopts its argument into `self.settings` on success,
    ///   leaving it untouched on failure, so `settings == bundle.settings` afterwards is exactly "the
    ///   settings write landed."
    @discardableResult
    func restore(from bundle: ConfigBundle) -> Bool {
        let libraryLanded = persistLibrary(groups: bundle.groups, globals: bundle.globals)
        update(bundle.settings)
        return libraryLanded && settings == bundle.settings
    }

    // MARK: The engine

    /// Hands the engine the library it matches against.
    ///
    /// Every path that changes `groups` or `globals` has to end here, or the expander goes on
    /// matching the library from before the edit. Loading is the only such path today; the editor
    /// adds the rest.
    private func pushLibrary() {
        engine.updateLibrary(groups: groups, globals: globals)
    }

    /// Everything that needs a launched app: the Dock icon, the app-switch observer, and the tap.
    ///
    /// Called from `applicationDidFinishLaunching`, which is the first moment there is an
    /// `NSApplication` to hold a permission prompt and a frontmost app worth asking about.
    func activate() {
        isActivated = true
        applyDockIconPolicy()
        observeAppSwitches()
        let frontmost = NSWorkspace.shared.frontmostApplication
        frontmostAppChanged(bundleID: frontmost?.bundleIdentifier, name: frontmost?.localizedName)
        refreshEngineState()
        reregisterHotKeys()
    }

    /// Takes the tap down on the way out.
    ///
    /// A running `KeystrokeMonitor` holds itself alive through its own thread, so quitting without
    /// this would leave the tap installed until the process died anyway — tidy rather than critical,
    /// but the monitor's contract asks for it and quitting is where it is owed.
    func deactivate() {
        isActivated = false
        engine.stop()
    }

    /// Recomputes the engine state from what is currently known, and makes the engine match it.
    ///
    /// Fail-closed, in this order:
    ///
    /// - Both stores have to have loaded. A library that failed to load has nothing to expand; a
    ///   settings file that failed to load means `engineEnabled` is this build's default of `true`
    ///   rather than the user's answer, and expanding into someone's typing on an assumed yes is the
    ///   one failure mode worth being paranoid about.
    /// - Both grants have to be in place *before* the tap is asked for. `CGEvent.tapCreate` is what
    ///   raises the Input Monitoring prompt, and that prompt is offered once and never again: asking
    ///   for it here, before onboarding has said what the app is for, would spend it on a dialogue
    ///   with no explanation attached. Accessibility is checked for the opposite reason — without it
    ///   injection fails silently, so an engine that ran without it would delete the user's trigger
    ///   and put nothing in its place.
    /// - Then the tap, whose failure is its own answer: `start()` returning `false` means Input
    ///   Monitoring, whatever the check above said a moment ago.
    ///
    /// Reading the two permission properties never prompts — only `PermissionsChecker`'s two
    /// functions do, and neither is called here.
    private func refreshEngineState() {
        guard canEditSnippets, canEditSettings, settings.engineEnabled, isActivated else {
            engine.stop()
            engineState = .paused
            return
        }
        guard PermissionsChecker.hasInputMonitoring, PermissionsChecker.hasAccessibility else {
            engine.stop()
            engineState = .permissionsMissing
            return
        }
        engineState = engine.start() ? .running : .permissionsMissing
    }

    /// Re-runs the checks above, for a permission that may have been granted since.
    ///
    /// Nothing tells an app that a TCC switch was flipped, and F Wrds does not poll: the app becoming
    /// active is the cheap approximation, since granting either permission means a trip to System
    /// Settings and back. Onboarding is where the real watching belongs.
    func recheckEngine() {
        guard isActivated else { return }
        refreshEngineState()
    }

    // MARK: Onboarding
    //
    // Both properties below are read once by `FWrdsApp.body`, to decide whether the "onboarding"
    // window scene's `.defaultLaunchBehavior` should present it, and if so at which step. They read
    // `PermissionsChecker` directly rather than `engineState`: `engineState` only reflects the grants
    // once `activate()` has run, and `activate()` runs from `applicationDidFinishLaunching`, which for
    // a `Window` scene's launch behaviour is later than `body` needs an answer.
    // `PermissionsChecker.hasAccessibility`/`hasInputMonitoring` are documented safe to read at any
    // time, so reading them straight from here — before this model has been activated at all — has no
    // ordering problem to work around.

    /// Whether onboarding should open the moment there is somewhere to show it: either this device has
    /// never finished it, or a grant it recorded has since gone missing, which for an unsigned build is
    /// exactly what an update losing TCC trust looks like — see `PermissionsChecker`'s own doc comment.
    var needsOnboardingAtLaunch: Bool {
        !UserDefaults.standard.hasCompletedOnboarding || onboardingShouldStartAtGrantsStep
    }

    /// Whether onboarding, if it opens, should skip the welcome step and land straight on the grants
    /// step: this device has completed onboarding before, but one of the two grants is missing now —
    /// the post-update recovery case, as opposed to a genuine first run.
    var onboardingShouldStartAtGrantsStep: Bool {
        UserDefaults.standard.hasCompletedOnboarding
            && (!PermissionsChecker.hasAccessibility || !PermissionsChecker.hasInputMonitoring)
    }

    /// Records an expansion for the menu's recents list. Called by the engine, on the main actor.
    private func recordExpansion(of snippet: Snippet) {
        recentSnippetIDs.removeAll { $0 == snippet.id }
        recentSnippetIDs.insert(snippet.id, at: 0)
        if recentSnippetIDs.count > Self.recentLimit {
            recentSnippetIDs.removeLast(recentSnippetIDs.count - Self.recentLimit)
        }
    }

    // MARK: The app in front

    /// Watches for app switches, so the matchable set follows the app the user is typing in.
    ///
    /// Observed here rather than inside the engine because two things need the answer and only one of
    /// them is the engine: the menu names the frontmost app in its pause item, and that has to be
    /// observable state on the main actor. One observer, one source of truth, and the engine is told.
    ///
    /// The observer lives as long as this model, which lives as long as the app; it captures `self`
    /// weakly so a model built for a preview or a test cannot be kept alive by it.
    private func observeAppSwitches() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            // Read out here, so that what crosses into the main actor below is two strings rather
            // than an `NSRunningApplication`. `queue: .main` is what makes the hop free and ordered:
            // the block is delivered on the main thread, which is the main actor's own executor.
            let bundleID = app?.bundleIdentifier
            let name = app?.localizedName
            MainActor.assumeIsolated { self?.frontmostAppChanged(bundleID: bundleID, name: name) }
        }
    }

    /// Points the engine at the app now in front, and remembers it for the menu.
    private func frontmostAppChanged(bundleID: String?, name: String?) {
        if bundleID != Bundle.main.bundleIdentifier {
            frontmostAppBundleID = bundleID
            frontmostAppName = name
        }
        // The engine is told the truth, including when the app in front is F Wrds itself: per-app
        // group rules are about where the caret actually is.
        engine.rebuildActiveSnippets(frontmostBundleID: bundleID)
    }

    /// Whether expansion is currently paused in `bundleID`.
    func isPaused(inApp bundleID: String) -> Bool {
        pausedAppBundleIDs.contains(bundleID)
    }

    /// Pauses or resumes expansion in one app, for this session.
    func setPaused(_ paused: Bool, inApp bundleID: String) {
        if paused {
            pausedAppBundleIDs.insert(bundleID)
        } else {
            pausedAppBundleIDs.remove(bundleID)
        }
        engine.setPausedApps(pausedAppBundleIDs)
    }

    // MARK: Expanding from the menu
    //
    // `pinnedSnippets`, `recentSnippets` and `snippet(id:)` live in `AppModel+Library.swift` — they
    // only read `groups`/`recentSnippetIDs`/`settings`, all readable cross-file already, so they
    // moved there with the rest of the library-shaped code once this class needed the room. What
    // stays here needs `engine`/`engineState`, which this class owns — `engine` losing its `private`
    // for `AppModel+Picker.swift` (see the note at its declaration) does not change that.

    /// Whether clicking a snippet in the menu could actually put text into another app.
    ///
    /// What injection itself needs is Accessibility — not the tap, not the engine toggle — which is
    /// why a paused or tap-failed engine still expands from the menu. Without that grant every
    /// method on `TextInjector` posts events that go nowhere, with no error to report, so the menu
    /// says so by switching the rows off rather than by doing nothing when they are clicked.
    ///
    /// The test is `engineState`, which is a slightly blunter instrument than that: it reads
    /// `.permissionsMissing` when *either* grant is missing, so a machine with Accessibility but not
    /// Input Monitoring has these rows switched off even though a click would in fact work. That is
    /// the right way round — the app is unusable in that state anyway, and onboarding is one menu
    /// item above — but it is a wider test than the sentence above on its own would suggest.
    var canExpandFromMenu: Bool {
        engineState != .permissionsMissing
    }

    /// Expands `snippet` into whatever the user was typing in, as if they had typed its trigger.
    ///
    /// Delayed, because the menu is still on screen at the moment of the click and F Wrds is the app
    /// in front: injecting now would put the expansion into the menu. The wait is the menu closing.
    ///
    /// It is a wait rather than a guarantee. Nothing reports "the menu has gone and the app behind it
    /// is back", so this is the window server being given long enough — and someone who switches to
    /// another app inside those 200 ms gets the expansion there instead.
    func expandFromMenu(_ snippet: Snippet) {
        let engine = self.engine
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.menuCloseDelay) {
            engine.expand(snippet)
        }
    }

    /// `StoreError` has no user-facing text of its own, and its `localizedDescription` is the
    /// generic "operation couldn't be completed" wrapper, so every case is spelled out here.
    ///
    /// Switching over the cast value rather than pattern-matching the existential is deliberate: it
    /// buys exhaustiveness checking, so a case added to `StoreError` fails this build instead of
    /// reaching a user as boilerplate.
    private static func describe(_ error: Error) -> String {
        guard let storeError = error as? StoreError else { return error.localizedDescription }
        switch storeError {
        case .unsupportedVersion(let version):
            return String(localized: "it was written by a newer version of F Wrds (file format \(version))")
        case .notLoaded:
            return String(localized: "F Wrds couldn't read the file it would overwrite")
        }
    }
}

extension AppModel {
    /// Whether this launch opens the manager window: the user's setting, unless setup is about to
    /// take the screen, in which case setup opens the window when it closes.
    var opensManagerAtLaunch: Bool {
        settings.openWindowAtLaunch && !needsOnboardingAtLaunch
    }

    /// Shows the Dock icon when the setting asks for it or while one of the app's windows is open,
    /// so an open window can always be reached from the Dock and ⌘Tab.
    ///
    /// `LSUIElement` starts the app as an agent, so `.regular` is what promotes it; call this once
    /// the app has finished launching and again whenever the setting or the open windows change.
    func applyDockIconPolicy() {
        let wanted: NSApplication.ActivationPolicy =
            settings.showDockIcon || hasVisibleAppWindow ? .regular : .accessory
        guard NSApp.activationPolicy() != wanted else { return }
        // The return value only reports whether the policy changed, which is not something the app
        // can act on: the setting is already saved either way.
        _ = NSApp.setActivationPolicy(wanted)
        if wanted == .regular, NSApp.isActive { Self.rebuildMenuBarOwnership() }
    }

    /// An agent app promoted to `.regular` while already active keeps a menu bar that draws but
    /// ignores clicks until it is deactivated and activated again. Handing activation to the Dock
    /// and straight back is the reliable way to do that without the user noticing.
    private static func rebuildMenuBarOwnership() {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
