import AppKit
import SwiftUI
import WrdsKit

/// The middle pane: the selected group's snippets — searchable, reorderable, each row a
/// trigger/label pair with an enabled toggle — and, at the bottom, where the group works.
///
/// App filters (`onlyInApps`/`neverInApps`) live on `SnippetGroup`, not `Snippet`, so they are
/// reached from here rather than from `SnippetEditorView`: this pane is the one that represents the
/// selected group.
struct SnippetListView: View {
    @Environment(AppModel.self) private var model
    let groupID: UUID

    @State private var searchText = ""
    @State private var showingAppFilters = false

    private var group: SnippetGroup? { model.group(id: groupID) }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { model.selectedSnippetID }, set: { model.selectSnippet($0) })) {
                ForEach(filteredSnippets) { snippet in
                    row(for: snippet)
                        .tag(snippet.id)
                }
                .onMove(perform: canReorder
                    ? { model.moveSnippets(in: groupID, fromOffsets: $0, toOffset: $1) } : nil)
            }
            .overlay {
                if group?.snippets.isEmpty == true {
                    ContentUnavailableView(
                        "No Snippets Yet", systemImage: "text.badge.plus",
                        description: Text("A snippet inserts text when you type its trigger. Add one with Add Snippet."))
                }
            }
            .searchable(text: $searchText, prompt: "Search snippets")
            Divider()
            HStack {
                Button("Add Snippet") { model.createSnippet(in: groupID) }
                    .buttonStyle(.bordered)
                    .disabled(!model.canEditSnippets)
                Spacer()
                Button { showingAppFilters = true } label: {
                    Label(appFilterSummary, systemImage: "macwindow")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
                .help("Choose which apps this group's snippets expand in")
            }
            .padding(8)
        }
        .navigationTitle(group?.name ?? String(localized: "Snippets"))
        .onChange(of: groupID) { _, _ in searchText = "" }
        .sheet(isPresented: $showingAppFilters) {
            AppFiltersSheet(groupID: groupID)
        }
    }

    // MARK: Snippets

    private var filteredSnippets: [Snippet] {
        guard let group else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return group.snippets }
        return group.snippets.filter { snippet in
            snippet.triggers.contains { $0.lowercased().contains(query) }
                || (snippet.regexTrigger?.lowercased().contains(query) ?? false)
                || snippet.label.lowercased().contains(query)
                || snippet.content.lowercased().contains(query)
        }
    }

    /// Reordering only makes sense against the group's real order, so it is switched off while a
    /// search is narrowing what is shown — moving a filtered row would silently reorder snippets that
    /// are not even on screen.
    private var canReorder: Bool {
        model.canEditSnippets && searchText.isEmpty && (group?.snippets.count ?? 0) > 1
    }

    private func row(for snippet: Snippet) -> some View {
        HStack(spacing: 8) {
            Toggle("Enabled", isOn: Binding(
                get: { snippet.isEnabled },
                set: { model.setSnippetEnabled(snippet.id, $0) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .disabled(!model.canEditSnippets)

            VStack(alignment: .leading, spacing: 2) {
                Text(triggerSummary(snippet))
                    .font(.system(.body, design: .monospaced))
                if !snippet.label.isEmpty {
                    Text(snippet.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if model.isPinned(snippet.id) {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Pinned to the menu bar")
                    .help("Pinned to the menu bar")
            }
        }
        .contextMenu {
            Button(model.isPinned(snippet.id) ? "Unpin from Menu Bar" : "Pin to Menu Bar") {
                model.togglePinned(snippet.id)
            }
            Divider()
            Button("Delete", role: .destructive) { model.requestDeleteSnippet(snippet.id) }
                .disabled(!model.canEditSnippets)
        }
        .listRowSeparator(.hidden)
    }

    private func triggerSummary(_ snippet: Snippet) -> String {
        if let regex = snippet.regexTrigger { return "/\(regex)/" }
        return snippet.triggers.isEmpty
            ? String(localized: "No trigger yet") : snippet.triggers.joined(separator: ", ")
    }

    private var appFilterSummary: String {
        let only = group?.onlyInApps.count ?? 0
        let never = group?.neverInApps.count ?? 0
        if only > 0 { return String(localized: "Only in \(only) apps") }
        if never > 0 { return String(localized: "Not in \(never) apps") }
        return String(localized: "All Apps")
    }
}

/// Where a group's snippets expand: only in some apps, never in others, or (both lists empty)
/// everywhere. A sheet rather than an inline section so it never competes with the snippet list
/// for room.
private struct AppFiltersSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let groupID: UUID

    @State private var presentingAppPicker: AppFilterKind?

    private var group: SnippetGroup? { model.group(id: groupID) }

    private enum AppFilterKind: Identifiable {
        case onlyIn
        case neverIn
        var id: Self { self }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Apps for \u{201C}\(group?.name ?? "")\u{201D}").font(.headline)
                Text("""
                    Snippets in this group expand in every app. To limit that, add apps to one of \
                    the lists below. Leave both empty to expand everywhere.
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Group {
                filterList(title: "Only in these apps", bundleIDs: group?.onlyInApps ?? [], kind: .onlyIn)
                filterList(title: "Never in these apps", bundleIDs: group?.neverInApps ?? [], kind: .neverIn)
            }
            .disabled(!model.canEditSnippets)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(item: $presentingAppPicker) { kind in
            AppPickerSheet(excluding: excludedBundleIDs(for: kind)) { bundleID in
                addApp(bundleID, to: kind)
            }
        }
    }

    private func filterList(
        title: LocalizedStringKey, bundleIDs: [String], kind: AppFilterKind
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.medium))
            if !bundleIDs.isEmpty {
                FlowLayout {
                    ForEach(bundleIDs, id: \.self) { bundleID in
                        appChip(bundleID, kind: kind)
                    }
                }
            }
            Button("Add App\u{2026}") { presentingAppPicker = kind }
        }
    }

    private func appChip(_ bundleID: String, kind: AppFilterKind) -> some View {
        HStack(spacing: 4) {
            Text(Self.displayName(forBundleID: bundleID))
            Button {
                removeApp(bundleID, from: kind)
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }

    private func excludedBundleIDs(for kind: AppFilterKind) -> Set<String> {
        switch kind {
        case .onlyIn: return Set(group?.onlyInApps ?? [])
        case .neverIn: return Set(group?.neverInApps ?? [])
        }
    }

    private func addApp(_ bundleID: String, to kind: AppFilterKind) {
        guard let group else { return }
        var only = group.onlyInApps
        var never = group.neverInApps
        switch kind {
        case .onlyIn: if !only.contains(bundleID) { only.append(bundleID) }
        case .neverIn: if !never.contains(bundleID) { never.append(bundleID) }
        }
        model.updateGroupAppFilters(groupID, onlyInApps: only, neverInApps: never)
    }

    private func removeApp(_ bundleID: String, from kind: AppFilterKind) {
        guard let group else { return }
        var only = group.onlyInApps
        var never = group.neverInApps
        switch kind {
        case .onlyIn: only.removeAll { $0 == bundleID }
        case .neverIn: never.removeAll { $0 == bundleID }
        }
        model.updateGroupAppFilters(groupID, onlyInApps: only, neverInApps: never)
    }

    private static func displayName(forBundleID bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let bundle = Bundle(url: url)
        else { return bundleID }
        return (bundle.infoDictionary?["CFBundleName"] as? String)
            ?? (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? bundleID
    }
}
