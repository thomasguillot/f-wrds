import AppKit
import SwiftUI
import WrdsKit

/// The default paste-vs-typed mode, plus a per-app override table backed by `AppPickerSheet` — the
/// same picker `SnippetListView`'s group app filters already use.
struct InjectionSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var isPickingApp = false

    var body: some View {
        Form {
            Section("Default method") {
                Picker("Method", selection: model.binding(\.defaultInjectionMode)) {
                    Text("Paste").tag(AppSettings.InjectionMode.paste)
                    Text("Typed").tag(AppSettings.InjectionMode.typed)
                }
                Text("""
                    Paste is fast and exact. Typed types the text key by key, for apps that don't \
                    accept a paste, such as terminals.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Exceptions by app") {
                if overrides.isEmpty {
                    Text("No exceptions yet. Every app uses the default method above.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(overrides) { row in
                        overrideRow(row)
                    }
                }
                Text("Add an app here if pasting doesn't work in it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Add App\u{2026}") { isPickingApp = true }
                    .disabled(!model.canEditSettings)
            }
        }
        .formStyle(.grouped)
        .disabled(!model.canEditSettings)
        .sheet(isPresented: $isPickingApp) {
            AppPickerSheet(excluding: Set(model.settings.perAppInjectionOverrides.keys)) { bundleID in
                addOverride(bundleID)
            }
        }
    }

    private func overrideRow(_ row: OverrideRow) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(Self.displayName(for: row.bundleID))
                Text(row.bundleID)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: modeBinding(for: row.bundleID)) {
                Text("Paste").tag(AppSettings.InjectionMode.paste)
                Text("Typed").tag(AppSettings.InjectionMode.typed)
            }
            .labelsHidden()
            .accessibilityLabel("Insertion method for \(Self.displayName(for: row.bundleID))")
            .frame(width: 100)
            Button {
                removeOverride(row.bundleID)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove exception for \(Self.displayName(for: row.bundleID))")
        }
    }

    private var overrides: [OverrideRow] {
        model.settings.perAppInjectionOverrides.keys
            .map { OverrideRow(bundleID: $0) }
            .sorted { Self.displayName(for: $0.bundleID) < Self.displayName(for: $1.bundleID) }
    }

    private func modeBinding(for bundleID: String) -> Binding<AppSettings.InjectionMode> {
        Binding(
            get: { model.settings.perAppInjectionOverrides[bundleID] ?? model.settings.defaultInjectionMode },
            set: { newValue in
                var updated = model.settings
                updated.perAppInjectionOverrides[bundleID] = newValue
                model.update(updated)
            }
        )
    }

    private func addOverride(_ bundleID: String) {
        var updated = model.settings
        updated.perAppInjectionOverrides[bundleID] = updated.defaultInjectionMode
        model.update(updated)
    }

    private func removeOverride(_ bundleID: String) {
        var updated = model.settings
        updated.perAppInjectionOverrides.removeValue(forKey: bundleID)
        model.update(updated)
    }

    /// The app's own name, when macOS can still find that bundle ID installed — falling back to the
    /// bundle ID itself (already shown as a caption beneath, so nothing is lost either way).
    private static func displayName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let bundle = Bundle(url: url)
        else { return bundleID }
        return (bundle.infoDictionary?["CFBundleName"] as? String) ?? bundleID
    }
}

private struct OverrideRow: Identifiable {
    var id: String { bundleID }
    let bundleID: String
}
