import SwiftUI
import WrdsKit

/// The pane the sidebar's fixed "Global Variables" row opens. Self-contained: a list of
/// `GlobalVariable`s on the left, a form for whichever one is selected on the right — the manager
/// window's three-column `NavigationSplitView` collapses to two columns (sidebar + this) while it is
/// showing, since a global variable has nothing that maps onto a middle "snippet list" column.
///
/// The per-kind fields are `VariableKindEditor`, the same view the snippet editor's chip popovers
/// use: one editor per `Variable.Kind` in this app, so a date's format field behaves identically
/// wherever a date is being configured.
struct GlobalsEditorView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedGlobalID: UUID?
    @State private var pendingDeleteID: UUID?

    var body: some View {
        HStack(spacing: 0) {
            list
            Divider()
            detail
        }
        .navigationTitle("Global Variables")
        .confirmationDialog(
            "Delete this variable?",
            isPresented: Binding(get: { pendingDeleteID != nil }, set: { if !$0 { pendingDeleteID = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let id = pendingDeleteID {
                    model.deleteGlobal(id)
                    if selectedGlobalID == id { selectedGlobalID = nil }
                }
                pendingDeleteID = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteID = nil }
        } message: {
            Text("Snippets that use it will insert nothing in its place. This can't be undone.")
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            List(selection: $selectedGlobalID) {
                ForEach(model.globals) { global in
                    HStack {
                        Text(global.variable.name)
                        Spacer()
                        Text(VariableKindOption(matching: global.variable.kind).title)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                    .tag(global.id)
                    .contextMenu {
                        Button("Delete", role: .destructive) { pendingDeleteID = global.id }
                            .disabled(!model.canEditSnippets)
                    }
                    .listRowSeparator(.hidden)
                }
            }
            Divider()
            Button("Add Variable") {
                if let id = model.createGlobal() { selectedGlobalID = id }
            }
            .buttonStyle(.bordered)
            .disabled(!model.canEditSnippets)
            .padding(8)
        }
        .frame(width: 220)
    }

    @ViewBuilder private var detail: some View {
        if let id = selectedGlobalID, model.globals.contains(where: { $0.id == id }) {
            GlobalVariableFormView(globalID: id)
                .disabled(!model.canEditSnippets)
        } else {
            ContentUnavailableView {
                Label(model.globals.isEmpty ? "No Global Variables" : "No Variable Selected",
                      systemImage: "curlybraces")
            } description: {
                Text("""
                    Save a value once, like your name or an email signature, and use it in any \
                    snippet. Change it here and every snippet that uses it updates.
                    """)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

}

/// The right-hand pane of `GlobalsEditorView`: a name, a kind, and `VariableKindEditor` for whatever
/// that kind needs.
private struct GlobalVariableFormView: View {
    @Environment(AppModel.self) private var model
    let globalID: UUID

    @State private var name = ""
    @State private var kind: Variable.Kind = .echo(value: "")
    @State private var nameError: String?
    @FocusState private var nameFocused: Bool

    private var original: GlobalVariable? { model.globals.first { $0.id == globalID } }

    var body: some View {
        Form {
            Section("Name") {
                TextField("Name", text: $name)
                    .focused($nameFocused)
                    .onChange(of: nameFocused) { was, now in if was, !now { commit() } }
                if let nameError {
                    Text(nameError).font(.caption).foregroundStyle(.red)
                }
            }
            Section("Type") {
                Picker("Type", selection: kindSelection) {
                    ForEach(VariableKindOption.globalCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Section {
                // No `globals` to offer, and `allowsGlobalReference: false`: a global that pointed at
                // another global would be an alias, and the renderer resolves globals one hop only.
                // `globalCases` leaves `.global` out of the picker for the same reason, so a library
                // carrying one — hand-edited, or imported — opens with no segment selected and the
                // editor says why rather than offering to point it at itself.
                VariableKindEditor(kind: $kind, allowsGlobalReference: false, onCommit: commit)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
        .onChange(of: globalID) { _, _ in commit(); load() }
        .onDisappear(perform: commit)
    }

    private var kindSelection: Binding<VariableKindOption> {
        Binding(
            get: { VariableKindOption(matching: kind) },
            set: { newKind in
                guard newKind != VariableKindOption(matching: kind) else { return }
                kind = newKind.defaultValue
                commit()
            }
        )
    }

    private func load() {
        guard let global = original else { return }
        name = global.variable.name
        kind = global.variable.kind
        nameError = nil
    }

    /// Persists whatever is on screen. A name that is blank, malformed or already taken stops the
    /// whole commit — including any kind edits made alongside it — so it says so rather than dropping
    /// the edit silently.
    ///
    /// Renaming here repoints every snippet variable that referred to this global by its old name;
    /// `AppModel.updateGlobal(_:to:)` is where that happens and why it has to.
    private func commit() {
        guard model.canEditSnippets, let existingID = original?.variable.id else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TokenSerialiser.isValidName(trimmedName) else {
            nameError = String(localized: """
                Start with a letter or underscore, then use letters, digits, hyphens or \
                underscores. Fix the name to save.
                """)
            return
        }
        // Two globals with one name would leave every snippet resolving whichever the renderer met
        // first, and the other unreachable for ever.
        guard !model.globals.contains(where: {
            $0.id != globalID && $0.variable.name == trimmedName
        }) else {
            nameError = String(localized: """
                Another global variable is already called \u{201C}\(trimmedName)\u{201D}. Choose a \
                different name to save.
                """)
            return
        }
        nameError = nil
        let variable = Variable(id: existingID, name: trimmedName, kind: kind)
        if let original, original.variable == variable { return }
        model.updateGlobal(globalID, to: variable)
    }
}
