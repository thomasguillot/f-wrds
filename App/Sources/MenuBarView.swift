import AppKit
import SwiftUI
import WrdsKit

/// The menu behind the status item: what the engine is doing, the two ways to stop it, the snippets
/// worth reaching without typing, and the ways out of a menu bar app.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(UpdateController.self) private var update
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Only when there is something to say. A line reading "Expanding snippets" above a switch
        // that already says so is a line nobody reads.
        if let statusLine {
            Text(statusLine)
            // The one problem onboarding can actually fix — a store failure or hotkey conflict has
            // nowhere in that flow to go.
            if model.engineState == .permissionsMissing {
                Button {
                    NSApp.activate()
                    openWindow(id: "onboarding")
                } label: {
                    Label("Open Setup\u{2026}", systemImage: "lock.shield")
                }
            }
            Divider()
        }
        if model.isEspansoRunning {
            Text("Espanso is running too, so snippets come out garbled.")
            Button {
                model.quitEspanso()
            } label: {
                Label("Quit Espanso", systemImage: "xmark.circle")
            }
            Divider()
        }
        // A hotkey conflict is unrelated to the engine, so it gets its own line rather than
        // outranking or being buried under the one above.
        if let hotKeyFailure = model.hotKeyFailure {
            Text(hotKeyFailure)
            Divider()
        }
        // A form submission that couldn't be delivered, similarly unrelated to the engine's own
        // running/paused state — and self-clearing, unlike the hotkey line above, since it describes
        // one past event rather than a condition still worth flagging every time the menu opens.
        if let formFailure = model.formFailure {
            Text(formFailure)
            Divider()
        }
        // A background check that failed has nowhere else to appear: the alert below is only shown
        // for a check the user asked for, and `updateItem` falls back to the plain "Check for
        // Updates…" whatever went wrong. Without this the app would quietly stop finding updates
        // and never say so. Phrased as a state rather than as an error, because a failed check
        // usually means the machine was offline a moment ago.
        if case .failed = update.state {
            Text("Couldn't check for updates")
            Divider()
        }

        Toggle(isOn: model.binding(\.engineEnabled)) {
            Label("Expand snippets", systemImage: "bolt.fill")
        }
        .disabled(!model.canEditSettings)
        if let bundleID = model.frontmostAppBundleID {
            Toggle(isOn: Binding(
                get: { model.isPaused(inApp: bundleID) },
                set: { model.setPaused($0, inApp: bundleID) }
            )) {
                Label("Pause in \(model.frontmostAppName ?? bundleID)", systemImage: "pause.fill")
            }
        }

        Divider()
        Button {
            model.openPickerFromMenu()
        } label: {
            Label(pickerItemTitle, systemImage: "magnifyingglass")
        }

        snippetSection("Pinned", model.pinnedSnippets, symbol: "pin.fill")
        snippetSection("Recent", model.recentSnippets, symbol: "clock")

        Divider()
        Button {
            NSApp.activate()
            openWindow(id: "manager")
        } label: {
            Label("Open F Wrds…", systemImage: "macwindow")
        }
        updateItem
        SettingsLink {
            Label("Settings…", systemImage: "gearshape")
        }
        Button {
            NSApp.activate()
            openWindow(id: "help")
        } label: {
            Label("Help", systemImage: "questionmark.circle")
        }
        Button {
            NSApp.activate()
            openWindow(id: "about")
        } label: {
            Label("About F Wrds", systemImage: "info.circle")
        }
        Divider()
        Button {
            NSApp.terminate(nil)
        } label: {
            Label("Quit F Wrds", systemImage: "xmark.rectangle")
        }
    }

    /// What the update menu item says and does, driven by `UpdateController.state` — an offer to
    /// install once a download is ready, a disabled "Checking…" while one is in flight, a way back
    /// into a download already under way, or the plain "Check for Updates…" the rest of the time.
    @ViewBuilder
    private var updateItem: some View {
        switch update.state {
        case .available, .readyToInstall:
            Button {
                Task { await update.showWindowOrCheck() }
            } label: {
                Label(updateAvailableTitle, systemImage: "arrow.down.circle.fill")
            }
        case .checking:
            Button {} label: {
                Label("Checking for Updates…", systemImage: "arrow.down.circle")
            }
            .disabled(true)
        case .downloading:
            Button {
                Task { await update.showWindowOrCheck() }
            } label: {
                Label("Downloading Update…", systemImage: "arrow.down.circle")
            }
        default:
            Button {
                Task { await update.checkNow(userInitiated: true) }
            } label: {
                Label("Check for Updates…", systemImage: "arrow.down.circle")
            }
        }
    }

    private var updateAvailableTitle: String {
        let version = update.plan.map { update.displayVersion($0.version) } ?? ""
        return String(localized: "Update to \(version)…")
    }

    /// One group of clickable snippets, or nothing at all when there are none to show. `symbol` marks
    /// which group this is — "pin.fill" for Pinned, "clock" for Recent — since both sections share
    /// this one builder.
    @ViewBuilder
    private func snippetSection(
        _ title: LocalizedStringKey, _ snippets: [Snippet], symbol: String
    ) -> some View {
        if !snippets.isEmpty {
            Divider()
            Section(title) {
                ForEach(snippets) { snippet in
                    Button {
                        model.expandFromMenu(snippet)
                    } label: {
                        Label(AppModel.displayName(of: snippet), systemImage: symbol)
                    }
                    // Without Accessibility the click would post events that never arrive, which
                    // would read as the app ignoring it. The status line above says why.
                    .disabled(!model.canExpandFromMenu)
                }
            }
        }
    }

    /// "Open Picker", with its hotkey alongside when one is set — a plain string rather than
    /// `.keyboardShortcut(_:modifiers:)`, since that binds a *local* SwiftUI shortcut for whenever
    /// this menu happens to be open, which is not what shows the global one Carbon has actually
    /// claimed and would double-fire it if both were live at once.
    private var pickerItemTitle: String {
        guard let spec = model.settings.pickerHotKey else { return String(localized: "Search Snippets") }
        return String(localized: "Search Snippets (\(spec.displayString))")
    }

    /// One line saying why nothing is expanding, or `nil` when everything is as it should be. A store
    /// failure outranks the engine: the detail is too long for a menu, so this points at the window
    /// that shows it in full.
    private var statusLine: String? {
        if model.storeFailure != nil {
            return String(localized: "F Wrds couldn't read or save something. Open the window for details.")
        }
        switch model.engineState {
        case .running: return nil
        case .paused: return String(localized: "Expansion paused")
        case .permissionsMissing: return String(localized: "Needs permission from macOS")
        case .tapFailed: return String(localized: "F Wrds can't watch the keyboard. Quit it and open it again.")
        }
    }
}
