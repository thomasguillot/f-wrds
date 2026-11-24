import Foundation
import SwiftUI
import WrdsKit

/// The content area: the chip editor, the Insert Variable menu, and the variables the content has
/// stopped mentioning.
///
/// Split out of `SnippetEditorView` because the two have almost nothing to say to each other — this
/// owns the editor's own view state (raw mode, the font, which chip's popover is open) and reaches
/// the snippet only through the draft binding it is handed.
struct SnippetContentSection: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: Snippet
    let undo: SnippetUndoController
    /// Persists the draft, recording the edit as an undo step when one is given.
    let onCommit: (SnippetEdit?) -> Void

    @State private var controller = ContentEditorController()
    @State private var isRawMode = false
    /// The chip whose popover is open, if any, and where in the editor it sits.
    @State private var chipVariableID: UUID?
    @State private var chipAnchor = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// The unused-variable chip whose popover is open. Separate state from `chipVariableID` because
    /// the two popovers hang off different views and would otherwise both try to present.
    @State private var unusedVariableID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            controls
            editor
            Text("Type the text this snippet inserts. Add variables for things that change.")
                .font(.caption)
                .foregroundStyle(.secondary)
            unusedVariablesRow
        }
        // This view survives a change of snippet — it is the same position in the hierarchy — so an
        // open popover would otherwise be left pointing at a variable belonging to the snippet that
        // was on screen a moment ago.
        .onChange(of: draft.id) { _, _ in
            chipVariableID = nil
            unusedVariableID = nil
        }
        // An undo can take away the variable a popover is showing.
        .onChange(of: draft.variables.map(\.id)) { _, ids in
            if let id = chipVariableID, !ids.contains(id) { chipVariableID = nil }
            if let id = unusedVariableID, !ids.contains(id) { unusedVariableID = nil }
        }
        .onAppear { undo.onContentRestored = { [controller] in controller.revealNextChange() } }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 12) {
            insertMenu
            Spacer()
            Toggle("Show raw tokens", isOn: $isRawMode)
                .help("Show the {{variables}} as text instead of chips")
        }
        .toggleStyle(.checkbox)
    }

    private var insertMenu: some View {
        Menu("Insert Variable") {
            Button("Date") { insert(.date(format: "%Y-%m-%d", offsetSeconds: 0), named: "date") }
            Button("Clipboard") { insert(.clipboard, named: "clipboard") }
            Button("Choice") { insert(.choice(options: []), named: "choice") }
            Button("Fixed text") { insert(.echo(value: ""), named: "echo") }
            Button("Shell") { insert(.shell(command: "", timeoutSeconds: 5), named: "shell") }
            Button("Ask me") {
                insert(.form(fields: [FormField(name: "field1", label: "Question 1",
                                                kind: .text(default: ""))]), named: "form")
            }
            Divider()
            Button("Global\u{2026}") {
                insert(.global(name: model.globals.first?.variable.name ?? ""), named: "global")
            }
            .disabled(model.globals.isEmpty)
            .help(model.globals.isEmpty ? String(localized: "Add a global variable first.") : "")
        }
        .help("Add something that changes each time, such as today's date.")
        .fixedSize()
        .disabled(!model.canEditSnippets)
    }

    // MARK: The editor

    private var editor: some View {
        ContentEditorView(
            text: $draft.content,
            documentID: draft.id,
            vocabulary: ChipVocabulary(variables: draft.variables),
            variables: draft.variables,
            isRawMode: isRawMode,
            isMonospaced: true,
            controller: controller,
            onChipClicked: { name, rect in
                guard let variable = draft.variables.first(where: { $0.name == name }) else { return }
                chipAnchor = rect
                chipVariableID = variable.id
            },
            onTextEdit: { content, continuing in
                undo.recordTyping(content: content, continuing: continuing)
            },
            onEndEditing: {
                undo.breakTyping()
                onCommit(nil)
            })
        .frame(minHeight: 180)
        .popover(
            isPresented: Binding(
                get: { chipVariableID != nil },
                set: { if !$0 { chipVariableID = nil } }),
            attachmentAnchor: .rect(.rect(chipAnchor)), arrowEdge: .bottom
        ) {
            configPopover(for: chipVariableID)
        }
    }

    @ViewBuilder private func configPopover(for id: UUID?) -> some View {
        if let id, draft.variables.contains(where: { $0.id == id }) {
            VariableConfigPopover(
                variable: variableBinding(id),
                globals: model.globals,
                takenNames: Set(draft.variables.filter { $0.id != id }.map(\.name)),
                onRename: { previous, updated in
                    draft.content = TokenSerialiser.renaming(previous, to: updated, in: draft.content)
                },
                onCommit: { onCommit(.changeVariable) })
            // VoiceOver can open another chip while this popover is still up; a fresh view per
            // variable keeps the name field from showing the previous one's.
            .id(id)
        }
    }

    // MARK: Variables the content no longer mentions

    /// Variables with no token naming them. Deleting a chip leaves the variable behind on purpose —
    /// it took configuring, and the usual reason a chip goes is that it is about to be put somewhere
    /// else — so they collect here, dimmed, with the two things worth doing to one.
    private var unusedVariables: [Variable] {
        let used = Set(TokenSerialiser.tokens(in: draft.content).map(\.name))
        return draft.variables.filter { !used.contains($0.name) }
    }

    @ViewBuilder private var unusedVariablesRow: some View {
        let unused = unusedVariables
        if !unused.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Variables not used in the content. Put one back or remove it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                FlowLayout { ForEach(unused) { unusedChip($0) } }
            }
        }
    }

    private func unusedChip(_ variable: Variable) -> some View {
        HStack(spacing: 6) {
            Button { unusedVariableID = variable.id } label: {
                Label(variable.name, systemImage: ChipVocabulary.symbol(for: variable.kind))
            }
            .buttonStyle(.plain)
            .help("Configure this variable")
            .popover(isPresented: Binding(
                get: { unusedVariableID == variable.id },
                set: { if !$0 { unusedVariableID = nil } }
            )) {
                configPopover(for: variable.id)
            }
            Button { reinsert(variable) } label: {
                Label("Insert", systemImage: "text.insert").labelStyle(.titleAndIcon)
            }
                .buttonStyle(.plain)
                .help("Put it back in the content, at the caret")
            Button { remove(variable) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
                .help("Remove it from this snippet")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
    }

    // MARK: Editing the draft

    /// Creates a variable, drops its token in at the caret, and opens its popover — a new variable
    /// always needs configuring, and the moment it is made is the moment to do it.
    private func insert(_ kind: Variable.Kind, named prefix: String) {
        guard model.canEditSnippets else { return }
        let name = TokenSerialiser.uniqueName(prefix: prefix, taken: Set(draft.variables.map(\.name)))
        let variable = Variable(name: name, kind: kind)
        draft.variables.append(variable)
        let rect = controller.insert(token: Self.token(for: variable),
                                     vocabulary: ChipVocabulary(variables: draft.variables))
        onCommit(.insertVariable)
        if let rect { chipAnchor = rect }
        chipVariableID = variable.id
    }

    private func reinsert(_ variable: Variable) {
        guard model.canEditSnippets else { return }
        controller.insert(token: Self.token(for: variable),
                          vocabulary: ChipVocabulary(variables: draft.variables))
        onCommit(.insertVariable)
    }

    private func remove(_ variable: Variable) {
        guard model.canEditSnippets else { return }
        draft.variables.removeAll { $0.id == variable.id }
        if unusedVariableID == variable.id { unusedVariableID = nil }
        if chipVariableID == variable.id { chipVariableID = nil }
        onCommit(.removeVariable)
    }

    /// The token that reads a variable. A form is several values rather than one, so its token
    /// addresses a field: `{{sign}}` on a form renders a `⚠︎`, `{{sign.name}}` renders an answer.
    private static func token(for variable: Variable) -> String {
        if case .form(let fields) = variable.kind, let first = fields.first {
            return "{{\(variable.name).\(first.name)}}"
        }
        return "{{\(variable.name)}}"
    }

    private func variableBinding(_ id: UUID) -> Binding<Variable> {
        Binding(
            get: {
                draft.variables.first { $0.id == id }
                    ?? Variable(id: id, name: "", kind: .echo(value: ""))
            },
            set: { updated in
                guard let index = draft.variables.firstIndex(where: { $0.id == id }) else { return }
                draft.variables[index] = updated
            }
        )
    }
}
