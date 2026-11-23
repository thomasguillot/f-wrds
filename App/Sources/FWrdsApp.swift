import AppKit
import SwiftUI

/// Holds the model for the life of the process and does the work that needs a running
/// `NSApplication`: the Dock icon policy, and the event tap's lifecycle.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let updateController = UpdateController()
    lazy var updateScheduler = UpdateScheduler(controller: updateController, model: model)

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.activate()
        updateScheduler.start()
        // `FWrdsApp.body` already decided, via `.defaultLaunchBehavior`, whether the "onboarding"
        // scene presents itself on this launch — see the long comment there. What it cannot do is
        // bring that window, or this `LSUIElement` app, to the front on its own: verified by launching
        // a clean build with another app active — the window was created (present in the process's
        // window list) but stayed unfocused behind it indefinitely. The plain `NSApp.activate()` this
        // app otherwise uses — see `MenuBarView`'s "Open Setup…"/"Open F Wrds…"/"About F Wrds…" —
        // turned out not to be enough either: macOS's newer, politer activation only honours a request
        // it can tie to a recent user gesture, and a launch with no window on screen yet to have been
        // clicked does not carry one. That is not a corner case here: `UpdateRelaunch.shellScript`
        // relaunches this app via a detached `/usr/bin/open` right after every update, which is
        // exactly the situation — and lands straight on `onboardingShouldStartAtGrantsStep`'s grants
        // recovery, the one onboarding run most likely to be silently skipped by a user who never sees
        // it appear. `ignoringOtherApps: true` is the one call verified to bring the window forward in
        // both cases; onboarding existing but not being seen defeats the point of it existing at all.
        if model.needsOnboardingAtLaunch || model.opensManagerAtLaunch {
            NSApp.activate(ignoringOtherApps: true)
        }
        observeAppWindows()
    }

    private func observeAppWindows() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDockForWindows(closing: nil) }
        }
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            let closing = note.object as? NSWindow
            MainActor.assumeIsolated { self?.refreshDockForWindows(closing: closing) }
        }
    }

    /// Panels (picker, form) and the status item's own window never count: only windows that can
    /// become main are ones a person would look for in the Dock.
    private func refreshDockForWindows(closing: NSWindow?) {
        let visible = NSApp.windows.contains { window in
            window !== closing && window.isVisible && !(window is NSPanel) && window.canBecomeMain
        }
        guard visible != model.hasVisibleAppWindow else { return }
        model.hasVisibleAppWindow = visible
        model.applyDockIconPolicy()
    }

    /// Becoming active is the app's cheapest sign that the user has been to System Settings and
    /// back — which is the only way either of the permissions the engine needs can appear.
    func applicationDidBecomeActive(_ notification: Notification) {
        model.recheckEngine()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.deactivate()
    }
}

/// The manager window's ⌘⌫: reads whatever the focused pane published via `\.deleteAction`
/// (`MainWindowView`), so the menu item and shortcut work without either side knowing about the
/// other beyond that one focused value.
private struct DeleteCommand: View {
    @FocusedValue(\.deleteAction) private var deleteAction

    var body: some View {
        Button("Delete", role: .destructive) { deleteAction?() }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(deleteAction == nil)
    }
}

/// The File menu's Espanso items, the same two actions the menu bar menu offers. Import opens the
/// manager window first, since that is where its preview appears.
private struct EspansoCommands: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Import from Espanso\u{2026}") {
            NSApp.activate()
            openWindow(id: "manager")
            model.startEspansoImport()
        }
        .disabled(!model.canEditSnippets)
        Button("Export to Espanso\u{2026}") {
            NSApp.activate()
            model.exportToEspanso()
        }
    }
}

/// Replaces the system-generated "About F Wrds" item — which would open a stock panel with no
/// icon, version, or link — with the `about` window declared below.
private struct AboutCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About F Wrds") {
            NSApp.activate()
            openWindow(id: "about")
        }
    }
}

/// Replaces the default Help menu, which has nothing in it, with the Help window, a way back into
/// setup, and the issue tracker.
private struct HelpCommands: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("F Wrds Help") {
            NSApp.activate()
            openWindow(id: "help")
        }
        .keyboardShortcut("?", modifiers: .command)
        Button("Run Setup Again\u{2026}") {
            NSApp.activate()
            openWindow(id: "onboarding")
        }
        Divider()
        Button("Report a Problem\u{2026}") {
            if let url = URL(string: "https://github.com/thomasguillot/f-wrds/issues/new") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

@main
struct FWrdsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(appDelegate.model)
                .environment(appDelegate.updateController)
        } label: {
            // The speech-bubble glyph. `MenuBarIcon` is a template PDF, so AppKit tints it to
            // match light and dark menu bars on its own; `.template` here is belt and suspenders.
            Image("MenuBarIcon")
                .renderingMode(.template)
        }
        .menuBarExtraStyle(.menu)

        Window("F Wrds", id: "manager") {
            MainWindowView()
                .frame(minWidth: 720, maxWidth: .infinity, minHeight: 460, maxHeight: .infinity)
                .environment(appDelegate.model)
        }
        // Setup takes the first launch to itself and opens this window when it is done.
        .defaultLaunchBehavior(appDelegate.model.opensManagerAtLaunch ? .presented : .suppressed)
        .defaultSize(width: 960, height: 620)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) { AboutCommand() }
            CommandGroup(after: .newItem) { EspansoCommands(model: appDelegate.model) }
            CommandGroup(after: .pasteboard) { DeleteCommand() }
            CommandGroup(replacing: .help) { HelpCommands() }
        }

        // First run, or a grant lost after an update — see `AppModel.needsOnboardingAtLaunch`. Read
        // once here, at the moment SwiftUI builds the scene graph, which is after
        // `@NSApplicationDelegateAdaptor` has already constructed `appDelegate.model` but is not tied
        // to `applicationDidFinishLaunching` having run — see that property's own doc comment for why
        // it does not need to be. `MenuBarView`'s "Open Setup…" reopens this window on demand the same
        // way, for whenever this launch check said no but something changes later in the session.
        Window("Set Up F Wrds", id: "onboarding") {
            OnboardingView(startAtGrantsStep: appDelegate.model.onboardingShouldStartAtGrantsStep)
                .environment(appDelegate.model)
        }
        .defaultLaunchBehavior(appDelegate.model.needsOnboardingAtLaunch ? .presented : .suppressed)
        .windowResizability(.contentSize)

        // Reachable from the app menu (`AboutCommand` above) and from the menu bar extra's own
        // "About F Wrds" row — see `MenuBarView`. A `Window` scene rather than
        // `NSApp.orderFrontStandardAboutPanel`, since the latter has no way to show the tagline.
        Window("About F Wrds", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)

        Window("F Wrds Help", id: "help") {
            HelpView()
                .frame(minWidth: 640, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
        }
        .defaultSize(width: 760, height: 520)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environment(appDelegate.model)
        }
    }
}
