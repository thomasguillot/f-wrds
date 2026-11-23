import AppKit
import SwiftUI

/// Login item, Dock icon, language override, and the auto-update toggle (Task 19 wires the updater
/// itself; this only persists the preference it will read).
struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model

    private let loginItem: LoginItemControlling = SMAppServiceLoginItem()
    /// The *real* login-item state, not `settings.launchAtLogin` — a login item can be turned off
    /// from System Settings without F Wrds ever hearing about it, and showing the stale persisted
    /// value would let this toggle lie about what actually happens on next boot. Seeded on
    /// `onAppear`; `settings.launchAtLogin` is kept as a mirror of this (see `launchAtLoginBinding`)
    /// so a `ConfigBundle` backup has something to restore, even though restoring it cannot itself
    /// flip the real registration — see `AppModel.restore(from:)`.
    @State private var isLoginItemEnabled = false
    @State private var loginItemError: String?

    @State private var isPromptingRelaunch = false

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch F Wrds at login", isOn: launchAtLoginBinding)
                if let loginItemError {
                    Text(loginItemError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Toggle("Open the F Wrds window at launch", isOn: model.binding(\.openWindowAtLaunch))
                Toggle("Always show icon in the Dock", isOn: model.binding(\.showDockIcon))
                Text("The Dock icon also shows while an F Wrds window is open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Language") {
                Picker("Language", selection: languageBinding) {
                    ForEach(LanguageChoice.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                Text("The language F Wrds' own menus and windows use.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Updates") {
                Toggle("Automatically check for updates",
                       isOn: model.binding(\.checkForUpdatesAutomatically))
            }
        }
        .formStyle(.grouped)
        .disabled(!model.canEditSettings)
        .onAppear { isLoginItemEnabled = loginItem.isEnabled }
        .confirmationDialog("Quit F Wrds to change language?", isPresented: $isPromptingRelaunch, titleVisibility: .visible) {
            Button("Quit") { NSApp.terminate(nil) }
            Button("Later", role: .cancel) {}
        } message: {
            Text("The new language applies the next time F Wrds opens.")
        }
    }

    /// Writes through both halves of "launch at login": the real registration (`loginItem`, via
    /// `LaunchAtLogin.apply`) and the persisted mirror (`settings.launchAtLogin`, via
    /// `AppModel.update(_:)` — the one settings write path, per the app-wide rule). `apply` always
    /// re-reads the real state after attempting the change, so a refusal (System Settings has
    /// "Allow in the Background" off for this app, say) snaps both the switch and the stored setting
    /// back to what is actually registered rather than to the click the user made.
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { isLoginItemEnabled },
            set: { newValue in
                let result = LaunchAtLogin.apply(newValue, to: loginItem)
                isLoginItemEnabled = result.isEnabled
                loginItemError = result.error
                var updated = model.settings
                updated.launchAtLogin = result.isEnabled
                model.update(updated)
            }
        )
    }

    /// Writes `settings.languageOverride` and the `AppleLanguages` override that actually changes
    /// what `Bundle.main` resolves strings against, then offers to quit so the change takes effect —
    /// there is no in-place relaunch for an unsigned app with no helper to hand the "come back up"
    /// baton to, so this is the honest version: tell the user, let them pick when.
    private var languageBinding: Binding<LanguageChoice> {
        Binding(
            get: { LanguageChoice(settingsValue: model.settings.languageOverride) },
            set: { newChoice in
                guard newChoice.settingsValue != model.settings.languageOverride else { return }
                var updated = model.settings
                updated.languageOverride = newChoice.settingsValue
                model.update(updated)
                if let code = newChoice.settingsValue {
                    UserDefaults.standard.set([code], forKey: "AppleLanguages")
                } else {
                    UserDefaults.standard.removeObject(forKey: "AppleLanguages")
                }
                isPromptingRelaunch = true
            }
        )
    }
}

/// The language picker's own vocabulary — `nil` reads as "System" and every other case is one of the
/// three overrides `AppSettings.languageOverride` documents. A dedicated enum rather than tagging the
/// `Picker` on `String?` directly: SwiftUI's optional-selection tagging has enough sharp edges that a
/// concrete, `CaseIterable` type is the safer and clearer choice for four fixed options.
private enum LanguageChoice: String, CaseIterable, Identifiable {
    case system
    case englishUK = "en-GB"
    case englishUS = "en"
    case french = "fr"

    var id: Self { self }

    /// Every case but `.system` names a language in its own tongue — the same convention macOS' own
    /// language picker uses — so those three are deliberately *not* run through `String(localized:)`:
    /// "English (UK)" reads the same whether F Wrds is currently speaking English or French, exactly
    /// as "Français" would look wrong translated to "French" while the app is in French.
    var label: String {
        switch self {
        case .system: return String(localized: "System")
        case .englishUK: return "English (UK)"
        case .englishUS: return "English (US)"
        case .french: return "Français"
        }
    }

    /// What this reads as in `AppSettings.languageOverride` — `nil` for `.system`, the raw value
    /// otherwise.
    var settingsValue: String? { self == .system ? nil : rawValue }

    init(settingsValue: String?) {
        self = Self.allCases.first { $0.settingsValue == settingsValue } ?? .system
    }
}
