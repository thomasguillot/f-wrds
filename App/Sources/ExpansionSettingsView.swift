import SwiftUI
import WrdsKit

/// The engine toggle, undo-on-backspace, and the two hotkey recorders.
struct ExpansionSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Engine") {
                Toggle("Expand snippets", isOn: model.binding(\.engineEnabled))
                Text("Off pauses F Wrds in every app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Press ⌫ right after an expansion to undo it",
                       isOn: model.binding(\.undoOnBackspace))
            }
            Section("Shortcuts") {
                HotKeyRecorderView(
                    label: "Search snippets",
                    value: pickerHotKeyBinding,
                    allowsClearing: false,
                    conflictsWith: model.settings.pauseHotKey)
                HotKeyRecorderView(
                    label: "Pause expansion",
                    value: pauseHotKeyBinding,
                    allowsClearing: true,
                    conflictsWith: model.settings.pickerHotKey)
                if let hotKeyFailure = model.hotKeyFailure {
                    Text(hotKeyFailure)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(!model.canEditSettings)
    }

    private var pickerHotKeyBinding: Binding<HotKeySpec?> {
        Binding(
            get: { model.settings.pickerHotKey },
            set: { newValue in
                var updated = model.settings
                updated.pickerHotKey = newValue
                model.update(updated)
            }
        )
    }

    private var pauseHotKeyBinding: Binding<HotKeySpec?> {
        Binding(
            get: { model.settings.pauseHotKey },
            set: { newValue in
                var updated = model.settings
                updated.pauseHotKey = newValue
                model.update(updated)
            }
        )
    }
}
