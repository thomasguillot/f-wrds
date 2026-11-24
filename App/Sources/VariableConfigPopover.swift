import SwiftUI
import WrdsKit

/// What clicking a chip opens: one variable's name, kind, and whatever that kind needs configuring.
///
/// The kind fields themselves come from `VariableKindEditor`, which the globals pane uses too — there
/// is one editor per `Variable.Kind` in this app, not one per pane.
///
/// **Renaming rewrites the content.** A variable's name is how the content addresses it, so a rename
/// that left `{{oldName}}` behind would silently break the snippet. `onRename` is handed the pair and
/// rewrites every token that named it, keeping any `.field` suffix. It is applied on submit and when
/// the popover goes away rather than per keystroke: a name half-typed is not a name, and rewriting
/// the content to match one would scatter half-names through it.
struct VariableConfigPopover: View {
    @Binding var variable: Variable
    let globals: [GlobalVariable]
    /// Names the snippet's *other* variables have taken. Two variables with one name would leave the
    /// renderer resolving whichever it met first, for ever.
    let takenNames: Set<String>
    /// Applies a rename to the snippet's content: old name, new name.
    let onRename: (String, String) -> Void
    let onCommit: () -> Void

    @State private var name = ""
    @State private var nameError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            ScrollView {
                VariableKindEditor(kind: $variable.kind, globals: globals, onCommit: onCommit)
                    .padding(.trailing, 2)
            }
            .frame(maxHeight: 300)
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { name = variable.name }
        // An undo or redo can rename the variable under the popover; without this, closing it would
        // apply the stale name all over again.
        .onChange(of: variable.name) { _, renamed in
            name = renamed
            nameError = nil
        }
        .onDisappear {
            applyRename()
            onCommit()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Name") {
                TextField("Name", text: $name)
                    .labelsHidden()
                    .onSubmit { applyRename() }
            }
            if let nameError {
                Text(nameError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Picker("Type", selection: kindSelection) {
                ForEach(VariableKindOption.allCases) { Text($0.title).tag($0) }
            }
        }
    }

    /// Switching kind resets the fields to that kind's defaults. A shell command and a date format
    /// have nothing to carry between them, and a half-migrated variable would be worse than an empty
    /// one: what is on screen is what will be saved.
    private var kindSelection: Binding<VariableKindOption> {
        Binding(
            get: { VariableKindOption(matching: variable.kind) },
            set: { option in
                guard option != VariableKindOption(matching: variable.kind) else { return }
                variable.kind = option.defaultValue
                onCommit()
            }
        )
    }

    private func applyRename() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != variable.name else {
            nameError = nil
            return
        }
        guard TokenSerialiser.isValidName(trimmed) else {
            nameError = String(localized: """
                Start with a letter or underscore, then use letters, digits, hyphens or \
                underscores.
                """)
            name = variable.name
            return
        }
        guard !takenNames.contains(trimmed) else {
            nameError = String(localized: """
                This snippet already has a variable called \u{201C}\(trimmed)\u{201D}.
                """)
            name = variable.name
            return
        }
        nameError = nil
        let previous = variable.name
        variable.name = trimmed
        onRename(previous, trimmed)
        onCommit()
    }
}
