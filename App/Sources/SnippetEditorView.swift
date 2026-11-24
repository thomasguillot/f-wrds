import Foundation
import SwiftUI
import WrdsKit

/// The detail pane: everything about one snippet — triggers, label, content, variables and options.
///
/// Edits are held in a local draft and only reach `AppModel` (and so disk, and the running engine)
/// immediately for discrete actions — adding or removing a trigger, flipping a toggle, switching
/// trigger mode, inserting or configuring a variable — and otherwise when a text field loses focus or
/// the pane goes away. An editor bound straight to the model would rewrite `store.json` on every
/// keystroke; this is the same draft-then-commit shape as `hosts-switchr`'s fragment editor, for the
/// same reason.
///
/// The content area and the preview under it are `SnippetContentSection` and `SnippetPreviewView`,
/// both driven by this draft: what the preview shows is the unsaved snippet, not the saved one.
struct SnippetEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    let snippetID: UUID

    @State private var draft = Snippet()
    @State private var newTrigger = ""
    @State private var triggerError: String?
    /// What the other trigger mode held when the user switched away from it, so switching back
    /// restores it. A snippet stores either triggers or a regex, never both, so without this one
    /// mis-click on the mode picker throws the other away.
    @State private var setAsideTriggers: [String] = []
    @State private var setAsideRegex: String?
    @State private var undo = SnippetUndoController()
    @FocusState private var newTriggerFocused: Bool
    @FocusState private var labelFocused: Bool
    @FocusState private var regexFocused: Bool

    private var original: Snippet? { model.snippet(id: snippetID) }
    private var isRegexMode: Bool { draft.regexTrigger != nil }
    private var conflicts: [String] { model.triggerConflicts(for: draft) }

    /// A snippet with no way to match anything can never fire — worth saying, but not worth blocking
    /// on: it is the ordinary state of a snippet the user has not finished typing a trigger into yet.
    /// An empty pattern does not surface as `regexError` — `NSRegularExpression` happily compiles
    /// `""`, matching everywhere and firing nothing usefully — so it is checked separately here.
    private var noTriggerWarning: String? {
        if isRegexMode {
            guard (draft.regexTrigger ?? "").isEmpty else { return nil }
            return String(localized: "This snippet won't expand until you add a regular expression.")
        }
        guard draft.triggers.isEmpty else { return nil }
        return String(localized: "This snippet won't expand until you add a trigger.")
    }

    private var regexError: String? {
        guard let pattern = draft.regexTrigger, !pattern.isEmpty else { return nil }
        do {
            _ = try NSRegularExpression(pattern: pattern)
            return nil
        } catch {
            return String(localized: "Not a valid regular expression: \(error.localizedDescription)")
        }
    }

    var body: some View {
        Form {
            Section {
                modePicker
                if isRegexMode { regexField } else { triggerField }
                if let noTriggerWarning {
                    Text(noTriggerWarning).font(.caption).foregroundStyle(.red)
                }
                ForEach(conflicts, id: \.self) { message in
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }
            }

            Section("Label") {
                TextField("Label", text: $draft.label, prompt: Text("Optional name, shown in lists and in search"))
                    .focused($labelFocused)
                    .onChange(of: labelFocused) { was, now in if was, !now { commit(.changeLabel) } }
            }

            Section("Content") {
                SnippetContentSection(draft: $draft, undo: undo, onCommit: commit)
            }

            Section("Preview") {
                SnippetPreviewView(snippet: draft, globals: model.globals)
            }

            Section("Options") {
                Toggle("Only expand after a space or punctuation", isOn: binding(\.wordBoundary, .changeOption))
                    .help("Expands only after a space or punctuation, so \u{201C}sig\u{201D} doesn't expand inside \u{201C}design\u{201D}.")
                Toggle("Match the case I type", isOn: binding(\.propagateCase, .changeOption))
                    .help("Type the trigger with a capital letter and the text follows. Type it in capitals and the text is in capitals.")
                Picker("Capital letters", selection: binding(\.uppercaseStyle, .changeOption)) {
                    Text("None").tag(UppercaseStyle?.none)
                    Text("First letter").tag(UppercaseStyle?.some(.capitalise))
                    Text("Each word").tag(UppercaseStyle?.some(.capitaliseWords))
                    Text("All capitals").tag(UppercaseStyle?.some(.uppercase))
                }
                .help("Used with Match the case I type. Choose how a capitalised trigger changes the text.")
                Toggle("Enabled", isOn: binding(\.isEnabled, .changeEnabled))
                    .help("Off keeps the snippet but stops it expanding.")
            }

            if !draft.unmapped.isEmpty {
                Section {
                    Label("Imported from Espanso", systemImage: "shippingbox")
                        .foregroundStyle(.secondary)
                        .help(draft.unmapped.keys.sorted().joined(separator: ", "))
                    Text("F Wrds doesn't use these Espanso settings, but keeps them and writes them back when you export.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(!model.canEditSnippets)
        .onAppear { load() }
        .onChange(of: snippetID) { _, _ in commit(); load() }
        .onChange(of: original) { _, stored in undo.storedSnippetChanged(to: stored) }
        .onChange(of: undoManager) { _, manager in undo.adopt(manager) }
        .onDisappear {
            commit()
            undo.end()
        }
    }

    // MARK: Trigger / regex

    private enum TriggerMode { case text, regex }

    private var modePicker: some View {
        Picker("Trigger type", selection: Binding(
            get: { isRegexMode ? TriggerMode.regex : .text },
            set: { switchMode(to: $0) }
        )) {
            Text("Text").tag(TriggerMode.text)
            Text("Regex").tag(TriggerMode.regex)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var triggerField: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !draft.triggers.isEmpty {
                FlowLayout {
                    ForEach(draft.triggers, id: \.self) { chip($0) }
                }
            }
            HStack {
                TextField("Add trigger", text: $newTrigger, prompt: Text("Type a trigger, like ;sig"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .focused($newTriggerFocused)
                    .onSubmit { addTrigger() }
                Button("Add", action: addTrigger)
                    .disabled(newTrigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let triggerError {
                Text(triggerError).font(.caption).foregroundStyle(.red)
            }
            Text("Pick something you won't type by accident, like ;sig. Regex matches a pattern instead of fixed text.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var regexField: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Regular expression", text: Binding(
                get: { draft.regexTrigger ?? "" },
                set: { draft.regexTrigger = $0 }
            ), prompt: Text("Regular expression"))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .focused($regexFocused)
            .onChange(of: regexFocused) { was, now in if was, !now { commit(.changeRegex) } }
            if let regexError {
                Label(regexError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
            }
            Text(regexHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var regexHelp: String {
        let base = String(localized: """
            Matches a pattern instead of fixed text. For example, :hi(?<name>\\w+) expands on \
            :hiAnna, and {{name}} in the content becomes Anna.
            """)
        guard !setAsideTriggers.isEmpty else { return base }
        return base + " " + String(localized: "Switch back to Text to get your triggers back.")
    }

    private func chip(_ trigger: String) -> some View {
        HStack(spacing: 4) {
            Text(trigger).font(.system(.body, design: .monospaced))
            Button { removeTrigger(trigger) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }

    private func switchMode(to mode: TriggerMode) {
        guard mode != (isRegexMode ? .regex : .text) else { return }
        switch mode {
        case .regex:
            setAsideTriggers = draft.triggers
            draft.triggers = []
            draft.regexTrigger = setAsideRegex ?? ""
        case .text:
            setAsideRegex = draft.regexTrigger
            draft.regexTrigger = nil
            draft.triggers = setAsideTriggers
        }
        commit(.changeTriggerType)
    }

    private func addTrigger() {
        let trimmed = newTrigger.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard trimmed.count <= 64 else {
            triggerError = String(localized: """
                \u{201C}\(trimmed)\u{201D} is longer than 64 characters, so it can't expand. Shorten it.
                """)
            return
        }
        guard !draft.triggers.contains(trimmed) else {
            triggerError = String(localized: """
                \u{201C}\(trimmed)\u{201D} is already one of this snippet's triggers.
                """)
            newTrigger = ""
            return
        }
        draft.triggers.append(trimmed)
        newTrigger = ""
        triggerError = nil
        commit(.addTrigger)
    }

    private func removeTrigger(_ trigger: String) {
        draft.triggers.removeAll { $0 == trigger }
        commit(.removeTrigger)
    }

    // MARK: Draft lifecycle

    private func binding<Value>(_ keyPath: WritableKeyPath<Snippet, Value>,
                                _ edit: SnippetEdit) -> Binding<Value> {
        Binding(
            get: { draft[keyPath: keyPath] },
            set: { newValue in
                draft[keyPath: keyPath] = newValue
                commit(edit)
            }
        )
    }

    private func load() {
        draft = original ?? Snippet(id: snippetID)
        newTrigger = ""
        triggerError = nil
        setAsideTriggers = []
        setAsideRegex = nil
        undo.begin(read: { draft }, write: { draft = $0 }, model: model, undoManager: undoManager)
        if model.consumePendingTriggerFocus(for: snippetID) {
            DispatchQueue.main.async { newTriggerFocused = true }
        }
    }

    /// Persists the draft's edits, recording `edit` as an undo step first when one is given.
    private func commit(_ edit: SnippetEdit? = nil) {
        if let edit, model.canEditSnippets { undo.record(edit, current: draft) }
        undo.save()
    }
}
