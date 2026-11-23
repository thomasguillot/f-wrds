import SwiftUI
import WrdsKit

/// The palette's content: a search field, then every matchable snippet grouped under its group's
/// name, or told there is nothing to search whatsoever.
///
/// `groups` arrives already filtered to what is offered *at all* — group and snippet `isEnabled`,
/// and the frontmost app's `onlyInApps`/`neverInApps` — by `AppModel.pickerGroups(forApp:)`, captured
/// once before the panel was shown. Everything this view does with `searchText` narrows that fixed
/// set further; it never asks for a fresh one.
///
/// ## Matching: contains, not subsequence-fuzzy
///
/// A command palette could reasonably do either. Contains is chosen because F Wrds' picker is search-
/// then-pick over a personal library of at most a few dozen snippets, not a huge indexed corpus:
/// substring matching is exact enough to predict ("typing part of the trigger, the label, or a word
/// from the content finds it") and does not produce the odd hits a subsequence match invites on short
/// queries — "sig" as a subsequence matches "seeing" (s-e-e-**i**-n-**g**… no: s, then i, then g, all
/// present in order) as readily as "signature", which is not what a two-second glance at a result list
/// wants to explain. There is also no ranking: results stay in the library's own group/snippet order
/// rather than being reordered by match quality, so the list does not reshuffle under someone's
/// fingers as they type.
struct PickerView: View {
    let groups: [PickerGroupEntry]
    /// Mirrors `AppModel.canExpandFromMenu` — `false` only while Accessibility/Input Monitoring are
    /// not both granted, in which case injection would post events that never arrive. Rows stay
    /// visible either way, dimmed and inert, the same treatment `MenuBarView` gives its own snippet
    /// buttons: the palette still explains what is in the library, it just cannot act on it yet.
    let canExpand: Bool
    let onExpand: (Snippet) -> Void
    let onCancel: () -> Void

    @State private var searchText = ""
    @State private var selectedID: UUID?
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            if filteredGroups.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                resultsList
            }
        }
        .frame(width: 560, height: 420)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onKeyPress(.upArrow) { moveSelection(by: -1); return .handled }
        .onKeyPress(.downArrow) { moveSelection(by: 1); return .handled }
        .onExitCommand(perform: onCancel)
        .onAppear {
            isSearchFocused = true
            selectedID = flatResults.first?.id
        }
        .onChange(of: searchText) { _, _ in
            selectedID = flatResults.first?.id
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search snippets", text: $searchText)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($isSearchFocused)
                .onSubmit(expandSelection)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(filteredGroups) { entry in
                        Section {
                            ForEach(entry.snippets) { snippet in
                                PickerRowView(
                                    snippet: snippet,
                                    groupName: searchText.isEmpty ? nil : entry.group.name,
                                    isSelected: snippet.id == selectedID,
                                    canExpand: canExpand
                                )
                                .id(snippet.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedID = snippet.id
                                    expandSelection()
                                }
                            }
                        } header: {
                            Text(entry.group.name)
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 14)
                                .padding(.top, 8)
                                .padding(.bottom, 2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: selectedID) { _, newValue in
                guard let newValue else { return }
                proxy.scrollTo(newValue, anchor: .center)
            }
        }
    }

    /// Nothing at all for this app versus nothing matching the search are different situations, and
    /// only one of them is fixed by typing something else.
    @ViewBuilder
    private var emptyState: some View {
        if groups.isEmpty {
            ContentUnavailableView(
                "No Snippets Here", systemImage: "text.badge.checkmark",
                description: Text("No snippets expand in this app. Check each group's app filter."))
        } else {
            ContentUnavailableView.search(text: searchText)
        }
    }

    // MARK: Searching

    private var filteredGroups: [PickerGroupEntry] {
        groups.compactMap { entry in
            let matched = entry.snippets.filter(matches)
            guard !matched.isEmpty else { return nil }
            return PickerGroupEntry(group: entry.group, snippets: matched)
        }
    }

    private var flatResults: [Snippet] {
        filteredGroups.flatMap(\.snippets)
    }

    private func matches(_ snippet: Snippet) -> Bool {
        guard !searchText.isEmpty else { return true }
        if Self.contains(snippet.triggers.joined(separator: " "), query: searchText) { return true }
        if Self.contains(snippet.label, query: searchText) { return true }
        if Self.contains(snippet.content, query: searchText) { return true }
        if let regex = snippet.regexTrigger, Self.contains(regex, query: searchText) { return true }
        return false
    }

    private static func contains(_ text: String, query: String) -> Bool {
        text.localizedCaseInsensitiveContains(query)
    }

    // MARK: Selection

    private func moveSelection(by delta: Int) {
        let results = flatResults
        guard !results.isEmpty else { return }
        guard let currentID = selectedID, let index = results.firstIndex(where: { $0.id == currentID })
        else {
            selectedID = results.first?.id
            return
        }
        // `%` alone would return a negative index for `delta == -1` at `index == 0` in Swift, since
        // the sign of `%` follows the dividend — the extra `+ results.count` is what makes this wrap
        // backwards from the first row to the last rather than crashing on a negative subscript.
        let newIndex = (index + delta + results.count) % results.count
        selectedID = results[newIndex].id
    }

    private func expandSelection() {
        guard canExpand, let id = selectedID, let snippet = flatResults.first(where: { $0.id == id })
        else { return }
        onExpand(snippet)
    }
}

/// One row: the trigger (or, for a regex-only snippet, the pattern), the label beneath it if there is
/// one, and — only while a search is narrowing the list across groups — the group it belongs to, so a
/// mixed result list still says at a glance where each row came from.
private struct PickerRowView: View {
    let snippet: Snippet
    let groupName: String?
    let isSelected: Bool
    let canExpand: Bool

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(triggerText)
                    .font(.system(.body, design: .monospaced))
                if !snippet.label.isEmpty {
                    Text(snippet.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if let groupName {
                Text(groupName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            isSelected ? Color.accentColor.opacity(0.18) : .clear,
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .padding(.horizontal, 6)
        .opacity(canExpand ? 1 : 0.4)
    }

    private var triggerText: String {
        if let first = snippet.triggers.first { return first }
        if let regex = snippet.regexTrigger { return "/\(regex)/" }
        return snippet.label.isEmpty ? String(localized: "Untitled snippet") : snippet.label
    }
}
