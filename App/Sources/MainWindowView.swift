import AppKit
import SwiftUI
import WrdsKit

/// The manager window: a groups sidebar, a snippet list for whichever group is selected, and an
/// editor for whichever snippet is selected — or, when the sidebar's fixed "Global Variables" row is
/// picked instead, `GlobalsEditorView` in place of the last two columns.
struct MainWindowView: View {
    @Environment(AppModel.self) private var model
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StoreFailureBanner()
            EspansoRunningBanner()
            if !model.canEditSnippets {
                // The banner above can be dismissed; this cannot, so the reason nothing here can be
                // edited is still legible after it is.
                Text("Editing is off because F Wrds couldn't read your snippet library.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Group {
                if model.isGlobalsSelected {
                    NavigationSplitView(columnVisibility: $columnVisibility) {
                        sidebar
                    } detail: {
                        GlobalsEditorView()
                    }
                } else {
                    NavigationSplitView(columnVisibility: $columnVisibility) {
                        sidebar
                    } content: {
                        contentColumn
                            .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 420)
                    } detail: {
                        detailColumn
                    }
                }
            }
        }
        .navigationTitle("F Wrds")
        .sheet(item: Binding(get: { model.pendingEspansoImport }, set: { model.pendingEspansoImport = $0 })) { pending in
            EspansoImportPreviewSheet(
                result: pending.result,
                existingGroups: model.groups,
                onCommit: { groups, renameNotes in
                    model.pendingEspansoImport = nil
                    // Lets the preview sheet finish dismissing before the report sheet is presented,
                    // rather than swapping one `.sheet(item:)` for another in the same run-loop turn.
                    DispatchQueue.main.async {
                        model.commitEspansoImport(groups: groups, globals: pending.result.globals,
                                                  notes: pending.result.unmappedReport + renameNotes)
                    }
                },
                onCancel: { model.pendingEspansoImport = nil }
            )
        }
        .sheet(item: Binding(get: { model.espansoImportSummary }, set: { model.espansoImportSummary = $0 })) { summary in
            EspansoImportReportSheet(lines: summary.lines, groupCount: summary.groupCount,
                                     snippetCount: summary.snippetCount) { model.espansoImportSummary = nil }
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: Binding(
                get: { model.pendingDeletion != nil },
                set: { if !$0 { model.cancelPendingDeletion() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { model.confirmPendingDeletion() }
            Button("Cancel", role: .cancel) { model.cancelPendingDeletion() }
        } message: {
            Text(deletionMessage)
        }
        .focusedSceneValue(\.deleteAction, deleteAction)
    }

    private var sidebar: some View {
        GroupsSidebarView()
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
    }

    @ViewBuilder private var contentColumn: some View {
        if let groupID = model.selectedGroupID {
            SnippetListView(groupID: groupID)
        } else if model.groups.isEmpty {
            ContentUnavailableView {
                Label("No Groups Yet", systemImage: "folder.badge.plus")
            } description: {
                Text("Snippets live in groups, like Work or Personal. Add a group in the sidebar, or import yours from Espanso.")
            } actions: {
                Button("Import from Espanso\u{2026}") { model.startEspansoImport() }
                    .disabled(!model.canEditSnippets)
            }
        } else {
            ContentUnavailableView(
                "No Group Selected", systemImage: "folder",
                description: Text("Pick a group in the sidebar to see its snippets."))
        }
    }

    @ViewBuilder private var detailColumn: some View {
        if let snippetID = model.selectedSnippetID {
            SnippetEditorView(snippetID: snippetID)
        } else {
            ContentUnavailableView(
                "No Snippet Selected", systemImage: "text.badge.plus",
                description: Text("Pick a snippet to edit it, or use Add Snippet to make one."))
        }
    }

    /// ⌘⌫: the selected snippet if there is one, else the selected group. `nil` while the globals
    /// pane is open — its own delete affordance is local to `GlobalsEditorView`, and this scene-wide
    /// action must not reach for a group/snippet selection the user cannot currently see. Also `nil`
    /// when `!canEditSnippets`, matching every context-menu Delete: without this, a selection left
    /// over from before a failed load would still open a normal-looking confirmation dialog whose
    /// "Delete" then silently no-ops inside `mutateLibrary` and dismisses as if it had worked.
    private var deleteAction: (() -> Void)? {
        guard model.canEditSnippets, !model.isGlobalsSelected,
              model.selectedSnippetID != nil || model.selectedGroupID != nil
        else { return nil }
        return { model.requestDeleteSelection() }
    }

    private var deletionTitle: String {
        switch model.pendingDeletion {
        case .group(let id):
            let name = model.group(id: id)?.name ?? String(localized: "this group")
            return String(localized: "Delete \u{201C}\(name)\u{201D}?")
        case .snippet:
            return String(localized: "Delete this snippet?")
        case nil:
            return ""
        }
    }

    private var deletionMessage: String {
        switch model.pendingDeletion {
        case .group(let id):
            let count = model.group(id: id)?.snippets.count ?? 0
            guard count > 0 else { return String(localized: "This can't be undone.") }
            return String(localized: "This also deletes \(count) snippets. This can't be undone.")
        case .snippet(let id):
            let name = model.snippet(id: id).map(AppModel.displayName(of:))
                ?? String(localized: "this snippet")
            return String(localized: "\u{201C}\(name)\u{201D} can't be recovered once deleted.")
        case nil:
            return ""
        }
    }
}
