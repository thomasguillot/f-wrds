import Foundation
import WrdsKit

/// One group's worth of snippets as `PickerView` offers them — a plain `Identifiable` struct rather
/// than a tuple so `ForEach` and `Equatable`-free `.compactMap` chains have something with real
/// identity to key off.
struct PickerGroupEntry: Identifiable {
    let group: SnippetGroup
    let snippets: [Snippet]
    var id: UUID { group.id }
}

/// Groups, snippets and global variables: every mutation `GroupsSidebarView`, `SnippetListView`,
/// `SnippetEditorView` and `GlobalsEditorView` can make. Split out of `AppModel.swift` because that
/// class body was over SwiftLint's line ceiling with this inlined — see the note at
/// `AppModel.persistLibrary(groups:globals:)` for how the two files divide the work.
extension AppModel {
    /// Applies `transform` to a working copy of `groups`/`globals` and persists it. Every mutation
    /// below ends here — the one seam between an in-memory edit and both the file and the running
    /// expander agreeing with it.
    ///
    /// - Returns: whether the write actually landed. Every existing caller below ignores this
    ///   (`persistLibrary`'s own `storeFailure` message is already the UI's answer for a failed edit),
    ///   so it stays `@discardableResult` — but `importLibrary(groups:globals:)` needs to tell its own
    ///   caller apart a landed import from one that silently didn't, which is exactly why this stopped
    ///   being `Void`.
    @discardableResult
    private func mutateLibrary(
        _ transform: (inout [SnippetGroup], inout [GlobalVariable]) -> Void
    ) -> Bool {
        guard canEditSnippets else { return false }
        var newGroups = groups
        var newGlobals = globals
        transform(&newGroups, &newGlobals)
        return persistLibrary(groups: newGroups, globals: newGlobals)
    }

    /// The group `SnippetListView` is showing, if any.
    func group(id: UUID) -> SnippetGroup? {
        groups.first { $0.id == id }
    }

    /// The snippet with this ID, wherever in the library it lives.
    func snippet(id: UUID) -> Snippet? {
        for group in groups {
            if let snippet = group.snippets.first(where: { $0.id == id }) { return snippet }
        }
        return nil
    }

    // MARK: Selection

    func selectGroup(_ id: UUID?) {
        selectedGroupID = id
        selectedSnippetID = nil
        isGlobalsSelected = false
    }

    func selectGlobals() {
        isGlobalsSelected = true
    }

    func selectSnippet(_ id: UUID?) {
        selectedSnippetID = id
    }

    /// Consumes `pendingTriggerFocusSnippetID` if it names `id` — the one-shot read
    /// `SnippetEditorView` uses to decide whether to focus its "add trigger" field on appearing.
    func consumePendingTriggerFocus(for id: UUID) -> Bool {
        guard pendingTriggerFocusSnippetID == id else { return false }
        pendingTriggerFocusSnippetID = nil
        return true
    }

    // MARK: Pinning and recents

    /// The snippets pinned to the top of the menu, in the order the user pinned them.
    ///
    /// A pinned ID whose snippet has since been deleted is dropped rather than shown as a gap;
    /// `deleteSnippet(_:)` is what tidies the stored list itself.
    var pinnedSnippets: [Snippet] {
        settings.pinnedSnippetIDs.compactMap(snippet(id:))
    }

    func isPinned(_ id: UUID) -> Bool {
        settings.pinnedSnippetIDs.contains(id)
    }

    /// The snippet list's context-menu action: adds or removes `id` from the front of the menu.
    func togglePinned(_ id: UUID) {
        var updated = settings
        if let idx = updated.pinnedSnippetIDs.firstIndex(of: id) {
            updated.pinnedSnippetIDs.remove(at: idx)
        } else {
            updated.pinnedSnippetIDs.append(id)
        }
        update(updated)
    }

    /// The most recently expanded snippets, minus anything already pinned above them.
    var recentSnippets: [Snippet] {
        let pinned = Set(settings.pinnedSnippetIDs)
        return recentSnippetIDs.filter { !pinned.contains($0) }.compactMap(snippet(id:))
    }

    // MARK: The picker

    /// The snippets `PickerView` offers for `bundleID`, grouped the same way the sidebar shows them —
    /// enabled snippets in enabled groups that this app is not excluded from by `onlyInApps`/
    /// `neverInApps`. A group left with nothing matchable after that (nothing enabled, or an app
    /// filter that excluded every snippet — impossible today since the filter is per-group, but
    /// harmless to guard) is dropped rather than shown as an empty section header.
    ///
    /// This mirrors `ExpansionEngine.matchable(in:forApp:pausedApps:)` with one deliberate
    /// difference: it does not consult the session pause list. Opening the picker and choosing a
    /// snippet by hand is an explicit request, the same as clicking one in the menu — see
    /// `canExpandFromMenu` — and a "pause in this app" the user set from the menu a minute ago should
    /// not also hide the one UI that still works there.
    func pickerGroups(forApp bundleID: String?) -> [PickerGroupEntry] {
        groups.compactMap { group in
            guard group.isEnabled else { return nil }
            if !group.onlyInApps.isEmpty {
                guard let bundleID, group.onlyInApps.contains(bundleID) else { return nil }
            }
            if let bundleID, group.neverInApps.contains(bundleID) { return nil }
            let snippets = group.snippets.filter(\.isEnabled)
            guard !snippets.isEmpty else { return nil }
            return PickerGroupEntry(group: group, snippets: snippets)
        }
    }

    // MARK: Groups

    @discardableResult
    func createGroup() -> UUID? {
        let group = SnippetGroup(name: "New Group")
        mutateLibrary { groups, _ in groups.append(group) }
        guard groups.contains(where: { $0.id == group.id }) else { return nil }
        selectGroup(group.id)
        return group.id
    }

    func renameGroup(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        mutateLibrary { groups, _ in
            guard let idx = groups.firstIndex(where: { $0.id == id }) else { return }
            groups[idx].name = trimmed
        }
    }

    func setGroupEnabled(_ id: UUID, _ enabled: Bool) {
        mutateLibrary { groups, _ in
            guard let idx = groups.firstIndex(where: { $0.id == id }) else { return }
            groups[idx].isEnabled = enabled
        }
    }

    /// Replaces a group's app filters wholesale — the app-picker sheet adds one bundle ID at a time,
    /// but always via the current lists plus or minus one, so a single setter is enough.
    func updateGroupAppFilters(_ id: UUID, onlyInApps: [String], neverInApps: [String]) {
        mutateLibrary { groups, _ in
            guard let idx = groups.firstIndex(where: { $0.id == id }) else { return }
            groups[idx].onlyInApps = onlyInApps
            groups[idx].neverInApps = neverInApps
        }
    }

    func deleteGroup(_ id: UUID) {
        mutateLibrary { groups, _ in groups.removeAll { $0.id == id } }
        // Only clear the selection if the group actually went away — a failed persist must not
        // discard a selection that is still valid.
        guard selectedGroupID == id, !groups.contains(where: { $0.id == id }) else { return }
        selectedGroupID = groups.first?.id
        selectedSnippetID = nil
    }

    func moveGroups(fromOffsets source: IndexSet, toOffset destination: Int) {
        mutateLibrary { groups, _ in groups.move(fromOffsets: source, toOffset: destination) }
    }

    // MARK: Espanso import

    /// Merges an Espanso import into the library: appends `groups` (already renamed by
    /// `EspansoImportPreviewSheet` to avoid colliding with an existing one) and every global in
    /// `globals` whose name is not already taken — by an existing global, or by another global
    /// earlier in this same batch. Additive only, in one `mutateLibrary` transaction: nothing already
    /// in the library is edited or removed, which is the whole difference between "import" and
    /// `restore(from:)`.
    ///
    /// A global's name is its only identity as far as `Variable.Kind.global(name:)` is concerned —
    /// two globals sharing one would leave a snippet's reference resolving to whichever happened to
    /// come first, silently. Skipping the collision is safer than guessing which one the user meant;
    /// `commitEspansoImport` folds the skipped names into the same report it shows for everything else
    /// the import could not carry straight across.
    ///
    /// - Returns: whether the write actually landed, and the names of every global that was skipped
    ///   because a same-named one already existed. The caller needs the first to know whether it is
    ///   safe to show a "here's what happened" report at all — `persistLibrary`'s own `storeFailure`
    ///   already says why a failed write didn't, and a report sheet listing renames and skips on top
    ///   of that would read as a success that never happened.
    @discardableResult
    func importLibrary(
        groups: [SnippetGroup], globals: [GlobalVariable]
    ) -> (succeeded: Bool, skippedGlobalNames: [String]) {
        let existingNames = Set(self.globals.map(\.variable.name))
        var skipped: [String] = []
        var accepted: [GlobalVariable] = []
        for global in globals {
            if existingNames.contains(global.variable.name)
                || accepted.contains(where: { $0.variable.name == global.variable.name }) {
                skipped.append(global.variable.name)
            } else {
                accepted.append(global)
            }
        }
        let succeeded = mutateLibrary { currentGroups, currentGlobals in
            currentGroups += groups
            currentGlobals += accepted
        }
        return (succeeded, skipped)
    }

    // MARK: Snippets

    @discardableResult
    func createSnippet(in groupID: UUID) -> UUID? {
        let newSnippet = Snippet()
        mutateLibrary { groups, _ in
            guard let idx = groups.firstIndex(where: { $0.id == groupID }) else { return }
            groups[idx].snippets.append(newSnippet)
        }
        guard snippet(id: newSnippet.id) != nil else { return nil }
        // Selects it and arms `pendingTriggerFocusSnippetID`, so the editor opens with its "add
        // trigger" field focused — the detail-pane equivalent of the sidebar's "new item opens
        // ready to rename".
        selectedGroupID = groupID
        selectedSnippetID = newSnippet.id
        pendingTriggerFocusSnippetID = newSnippet.id
        return newSnippet.id
    }

    /// Replaces one snippet wherever it lives. The caller (the editor) already knows the snippet's
    /// group when it matters; this searches instead of asking for it, matching `snippet(id:)`.
    func updateSnippet(_ snippet: Snippet) {
        mutateLibrary { groups, _ in
            for idx in groups.indices {
                if let sIdx = groups[idx].snippets.firstIndex(where: { $0.id == snippet.id }) {
                    groups[idx].snippets[sIdx] = snippet
                    return
                }
            }
        }
    }

    func setSnippetEnabled(_ id: UUID, _ enabled: Bool) {
        guard var target = snippet(id: id) else { return }
        target.isEnabled = enabled
        updateSnippet(target)
    }

    /// Deletes a snippet and, since a pin naming it would otherwise dangle, unpins it too.
    func deleteSnippet(_ id: UUID) {
        mutateLibrary { groups, _ in
            for idx in groups.indices { groups[idx].snippets.removeAll { $0.id == id } }
        }
        if selectedSnippetID == id, snippet(id: id) == nil { selectedSnippetID = nil }
        if settings.pinnedSnippetIDs.contains(id) {
            var updated = settings
            updated.pinnedSnippetIDs.removeAll { $0 == id }
            update(updated)
        }
    }

    func moveSnippets(in groupID: UUID, fromOffsets source: IndexSet, toOffset destination: Int) {
        mutateLibrary { groups, _ in
            guard let idx = groups.firstIndex(where: { $0.id == groupID }) else { return }
            groups[idx].snippets.move(fromOffsets: source, toOffset: destination)
        }
    }

    /// Other enabled snippets whose triggers exactly match, or shadow, one of `snippet`'s triggers —
    /// one message per conflicting snippet, naming it.
    ///
    /// "Shadow" means one trigger is a suffix of the other: `TriggerMatcher` fires as soon as the
    /// typed buffer's tail equals any registered trigger, so a shorter trigger that is the tail of a
    /// longer one completes before the longer one can ever finish being typed. Regex-mode snippets
    /// (empty `triggers`) are not compared on either side — there is no cheap way to decide whether
    /// two regexes can match the same text, and a missed conflict is safer than a false alarm on
    /// every pair of regex snippets in the library.
    func triggerConflicts(for snippet: Snippet) -> [String] {
        guard snippet.isEnabled, !snippet.triggers.isEmpty else { return [] }
        var messages: [String] = []
        for group in groups {
            for other in group.snippets
            where other.id != snippet.id && other.isEnabled && !other.triggers.isEmpty {
                guard let pair = Self.conflictingPair(snippet.triggers, other.triggers) else { continue }
                messages.append(String(localized: """
                    \u{201C}\(pair.0)\u{201D} overlaps with \u{201C}\(pair.1)\u{201D} in \
                    \(Self.displayName(of: other)).
                    """))
            }
        }
        return messages
    }

    private static func conflictingPair(_ mine: [String], _ theirs: [String]) -> (String, String)? {
        for candidate in mine {
            if let match = theirs.first(where: {
                $0 == candidate || candidate.hasSuffix($0) || $0.hasSuffix(candidate)
            }) {
                return (candidate, match)
            }
        }
        return nil
    }

    /// What to call a snippet with no label: its first trigger, or its regex, or a last resort.
    /// Shared with `MenuBarView`, which names snippets in the menu the same way.
    static func displayName(of snippet: Snippet) -> String {
        if !snippet.label.isEmpty { return snippet.label }
        if let first = snippet.triggers.first { return first }
        if let regex = snippet.regexTrigger { return "/\(regex)/" }
        return String(localized: "Untitled snippet")
    }

    // MARK: Global variables

    @discardableResult
    func createGlobal() -> UUID? {
        let global = GlobalVariable(variable: Variable(name: uniqueGlobalName(), kind: .echo(value: "")))
        mutateLibrary { _, globals in globals.append(global) }
        guard globals.contains(where: { $0.id == global.id }) else { return nil }
        return global.id
    }

    /// Replaces a global, and — when its name changed — repoints every snippet variable that referred
    /// to it by the old name.
    ///
    /// The cascade is the whole reason this is not a one-line setter. A `Variable.Kind.global(name:)`
    /// holds the target's name, not its ID, so renaming a global without it would leave every
    /// referencing snippet resolving a name nothing answers to — which `ExpansionRenderer` renders as
    /// a `⚠︎` in the middle of the user's document, silently, at expansion time. It happens inside the
    /// one `mutateLibrary` transaction so the rename and the repointing reach disk together or not at
    /// all.
    ///
    /// What is deliberately *not* rewritten is `{{oldName}}` written directly into a snippet's
    /// content. Those were always by-name references in text — the editor does not even chip them —
    /// and rewriting a user's prose on the strength of a name match is a bigger liberty than leaving
    /// a reference for them to fix.
    func updateGlobal(_ id: UUID, to variable: Variable) {
        mutateLibrary { groups, globals in
            guard let idx = globals.firstIndex(where: { $0.id == id }) else { return }
            let previousName = globals[idx].variable.name
            globals[idx].variable = variable
            guard previousName != variable.name else { return }
            Self.repointGlobalReferences(from: previousName, to: variable.name, in: &groups)
        }
    }

    /// Rewrites `.global(name: previous)` to `.global(name: updated)` wherever a snippet's variables
    /// hold one.
    private static func repointGlobalReferences(from previous: String, to updated: String,
                                                in groups: inout [SnippetGroup]) {
        let target = Variable.Kind.global(name: previous)
        for groupIndex in groups.indices {
            for snippetIndex in groups[groupIndex].snippets.indices {
                let variables = groups[groupIndex].snippets[snippetIndex].variables
                guard variables.contains(where: { $0.kind == target }) else { continue }
                groups[groupIndex].snippets[snippetIndex].variables = variables.map { variable in
                    guard variable.kind == target else { return variable }
                    var repointed = variable
                    repointed.kind = .global(name: updated)
                    return repointed
                }
            }
        }
    }

    func deleteGlobal(_ id: UUID) {
        mutateLibrary { _, globals in globals.removeAll { $0.id == id } }
    }

    /// "variable1", "variable2"… — the first name not already in use, so a freshly created global
    /// never collides with one the user already has.
    ///
    /// No space in it, unlike the first version of this: a name is what a `{{token}}` spells, and
    /// `{{variable 2}}` matches neither the editor's token pattern nor the renderer's, so a global
    /// named that way could never be referenced by anything.
    private func uniqueGlobalName() -> String {
        TokenSerialiser.uniqueName(prefix: "variable", taken: Set(globals.map(\.variable.name)))
    }

    // MARK: Deletion confirmation

    func requestDeleteGroup(_ id: UUID) { pendingDeletion = .group(id) }
    func requestDeleteSnippet(_ id: UUID) { pendingDeletion = .snippet(id) }

    /// What ⌘⌫ deletes: the selected snippet if there is one, else the selected group.
    func requestDeleteSelection() {
        if let id = selectedSnippetID { pendingDeletion = .snippet(id) }
        else if let id = selectedGroupID { pendingDeletion = .group(id) }
    }

    func confirmPendingDeletion() {
        guard let pending = pendingDeletion else { return }
        switch pending {
        case .group(let id): deleteGroup(id)
        case .snippet(let id): deleteSnippet(id)
        }
        pendingDeletion = nil
    }

    func cancelPendingDeletion() {
        pendingDeletion = nil
    }
}
