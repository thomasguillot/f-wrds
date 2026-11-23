import SwiftUI

/// The Settings window: General (login item, Dock icon, language, updates), Expansion (engine
/// toggles, undo, the two hotkey recorders), Injection (default mode + per-app overrides), and Backup
/// (whole-config export/import via `ConfigBundle`) — each its own file, since every one of them grew
/// past a single `Section`.
struct SettingsView: View {
    var body: some View {
        VStack(spacing: 0) {
            // A save that fails happens here, so it has to be readable here: the manager window is
            // suppressed at launch and may never have been opened.
            StoreFailureBanner()
            TabView {
                GeneralSettingsView()
                    .tabItem { Label("General", systemImage: "gearshape") }
                ExpansionSettingsView()
                    .tabItem { Label("Expansion", systemImage: "bolt.fill") }
                InjectionSettingsView()
                    .tabItem { Label("Insertion", systemImage: "text.cursor") }
                BackupSettingsView()
                    .tabItem { Label("Backup and Espanso", systemImage: "externaldrive") }
            }
        }
        .frame(width: 520, height: 480)
    }
}
