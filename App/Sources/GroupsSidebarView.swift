import SwiftUI
import WrdsKit

/// The sidebar: every group, drag-reordered with `onMove`, plus a fixed "Global Variables" row
/// beneath them that switches the whole window over to `GlobalsEditorView`.
///
/// New groups open ready to rename and ⌘⌫ deletes the current selection with a confirmation — the
/// same interaction shape as this app's sibling projects' sidebars (see `ProfileSidebarView` and
/// `FragmentsSidebarView`), adapted to a selection that can point at a group *or* the fixed row.
struct GroupsSidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var renamingID: UUID?
    @State private var renameText = ""
    @FocusState private var renameFocus: UUID?

    @State private var exportDocument = YAMLDocument(text: "")
    @State private var exportFilename = "Untitled"
    @State private var isExportingGroup = false
    @State private var exportError: String?

    var body: some View {
        List(selection: sidebarSelection) {
            Label("Global Variables", systemImage: "curlybraces")
                .tag(SidebarSelection.globals)
                .listRowSeparator(.hidden)

            Section("Groups") {
                ForEach(model.groups) { group in
                    row(for: group)
                        .tag(SidebarSelection.group(group.id))
                        .contextMenu { contextMenu(for: group) }
                        .listRowSeparator(.hidden)
                }
                .onMove(perform: model.canEditSnippets && model.groups.count > 1
                    ? { model.moveGroups(fromOffsets: $0, toOffset: $1) } : nil)

                Button("Add Group") { createAndRename() }
                    .buttonStyle(.bordered)
                    .disabled(!model.canEditSnippets)
                    .padding(.top, 8)
                    .listRowSeparator(.hidden)
            }
        }
        .onChange(of: renameFocus) { _, new in if new == nil, renamingID != nil { commitRename() } }
        .onKeyPress(.return) {
            guard renamingID == nil, model.canEditSnippets,
                  let id = model.selectedGroupID,
                  let group = model.groups.first(where: { $0.id == id })
            else { return .ignored }
            startRename(group)
            return .handled
        }
        .navigationTitle("F Wrds")
        .fileExporter(isPresented: $isExportingGroup, document: exportDocument, contentType: EspansoUTType.yml,
                      defaultFilename: exportFilename) { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
        .alert("Couldn't Export", isPresented: Binding(
            get: { exportError != nil }, set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
    }

    private func row(for group: SnippetGroup) -> some View {
        HStack(spacing: 8) {
            Toggle("Enabled", isOn: enabledBinding(group))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(!model.canEditSnippets)
                .help("Turn this group's snippets on or off")
            if renamingID == group.id {
                TextField("Name", text: $renameText)
                    .textFieldStyle(.plain)
                    .focused($renameFocus, equals: group.id)
                    .onSubmit { commitRename() }
                    .onExitCommand { renamingID = nil }
            } else {
                Text(group.name)
            }
            Spacer()
            Text("\(group.snippets.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func contextMenu(for group: SnippetGroup) -> some View {
        Button("Rename") { startRename(group) }
            .disabled(!model.canEditSnippets)
        Button("Export\u{2026}") { beginExport(group) }
        Divider()
        Button("Delete", role: .destructive) { model.requestDeleteGroup(group.id) }
            .disabled(!model.canEditSnippets)
    }

    private var sidebarSelection: Binding<SidebarSelection?> {
        Binding(
            get: {
                if model.isGlobalsSelected { return .globals }
                if let id = model.selectedGroupID { return .group(id) }
                return nil
            },
            set: { newValue in
                switch newValue {
                case .group(let id): model.selectGroup(id)
                case .globals: model.selectGlobals()
                case nil: break
                }
            }
        )
    }

    private func enabledBinding(_ group: SnippetGroup) -> Binding<Bool> {
        Binding(get: { group.isEnabled }, set: { model.setGroupEnabled(group.id, $0) })
    }

    private func startRename(_ group: SnippetGroup) {
        model.selectGroup(group.id)
        renameText = group.name
        renamingID = group.id
        renameFocus = group.id
    }

    private func createAndRename() {
        guard let id = model.createGroup(), let group = model.groups.first(where: { $0.id == id })
        else { return }
        renameText = group.name
        renamingID = id
        DispatchQueue.main.async { renameFocus = id }
    }

    private func commitRename() {
        guard let id = renamingID else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { model.renameGroup(id, to: trimmed) }
        renamingID = nil
    }

    /// Renders `group` to an Espanso match file and opens the save panel. Not gated on
    /// `canEditSnippets` — exporting only reads the group, and it stays useful as a way to get a
    /// group's contents out even while the library can't be edited (a corrupt-file recovery, say).
    private func beginExport(_ group: SnippetGroup) {
        exportDocument = YAMLDocument(text: EspansoExporter.export(group: group, globals: model.globals))
        exportFilename = EspansoFilename.sanitized(group.name)
        isExportingGroup = true
    }
}

/// What the sidebar's single `List` selection can point at: a group, or the fixed row below them.
private enum SidebarSelection: Hashable {
    case group(UUID)
    case globals
}
