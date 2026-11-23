import SwiftUI
import WrdsKit

/// One incoming group's row in `EspansoImportPreviewSheet` — `name` is what the sheet is offering to
/// call it, always editable; `originalName` is what the file called it, kept so the row can say when
/// the two have drifted.
private struct PreviewRow: Identifiable {
    let id = UUID()
    var group: SnippetGroup
    var name: String
    let originalName: String
    var snippetCount: Int { group.snippets.count }

    /// Every shell command this group's snippets would run, in the order they appear.
    ///
    /// Espanso's `type: shell` maps straight onto this app's shell variable, and an imported one
    /// arrives enabled: from the moment Import is pressed, a trigger in someone else's match file
    /// runs a command on this machine. That is the honest behaviour of the format and is not being
    /// changed here — but a preview that showed only names and counts was asking for consent to
    /// something it had not mentioned, so the commands are named on the row that would import them.
    var shellCommands: [String] {
        group.snippets.flatMap { snippet in
            snippet.variables.compactMap { variable in
                guard case .shell(let command, _) = variable.kind else { return nil }
                return command
            }
        }
    }
}

/// Shown after a successful `EspansoImporter.importFiles` and before anything reaches the library:
/// every incoming group, its snippet count, and an editable name — pre-filled with a `" (imported)"`
/// suffix wherever the group's own name already collides (case-insensitively) with one already in the
/// library, so the import stays additive rather than silently merging into or renaming something the
/// user already has.
struct EspansoImportPreviewSheet: View {
    let result: EspansoImportResult
    let existingGroups: [SnippetGroup]
    /// The groups to actually add, each carrying its final (possibly renamed) name, plus one report
    /// line per rename actually made — folded into the post-import report alongside
    /// `result.unmappedReport`.
    let onCommit: (_ groups: [SnippetGroup], _ renameNotes: [String]) -> Void
    let onCancel: () -> Void

    @State private var rows: [PreviewRow] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(headline).font(.headline)
                Spacer()
                Button("Cancel") { onCancel() }
            }
            .padding()

            Text("""
                Where a name is already in your library, a new one is suggested below. You can \
                edit any name before importing.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.bottom, 8)

            shellWarning(
                String(localized: """
                    Global variables that run shell commands on your Mac \
                    (\(globalShellCommands.count))
                    """),
                commands: globalShellCommands)
                .padding(.horizontal)
                .padding(.bottom, 8)

            List($rows) { $row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        TextField("Group name", text: $row.name)
                            .textFieldStyle(.plain)
                        if row.name.lowercased() != row.originalName.lowercased() {
                            Text("was \u{201C}\(row.originalName)\u{201D}")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(row.snippetCount) snippets")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    shellWarning(
                        String(localized: """
                            Runs shell commands on your Mac when expanded \
                            (\(row.shellCommands.count))
                            """),
                        commands: row.shellCommands)
                }
            }

            Divider()
            HStack {
                Spacer()
                Button("Import") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(rows.contains { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            }
            .padding()
        }
        .frame(width: 480, height: 420)
        .onAppear(perform: buildRows)
    }

    private var headline: String {
        String(localized: "Import \(result.groups.count) groups")
    }

    /// Every shell command the incoming *shared* variables would run.
    ///
    /// Globals are imported once rather than per group, so they have no row of their own to be
    /// disclosed on — and an Espanso file's `global_vars` can declare `type: shell` exactly as a
    /// match's own variables can. Without this they would be the one way a command could arrive
    /// without ever being shown.
    private var globalShellCommands: [String] {
        result.globals.compactMap { global in
            guard case .shell(let command, _) = global.variable.kind else { return nil }
            return command
        }
    }

    /// A shell disclosure, or nothing when there are no commands to disclose.
    ///
    /// Collapsed by default and expandable, rather than a wall of commands on every row: the count
    /// is what someone needs to notice, and the commands themselves are what they need to be able to
    /// read before deciding. Selectable, because the natural next step for an unfamiliar command is
    /// to paste it somewhere and look at it.
    ///
    /// Import is not disabled or defaulted off by this. Running a command on expansion is what a
    /// shell variable *is*, and a file the user went and chose is not something this app should
    /// second-guess — it just has to say so before it happens rather than after.
    @ViewBuilder
    private func shellWarning(_ title: String, commands: [String]) -> some View {
        if !commands.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(commands.enumerated()), id: \.offset) { _, command in
                        Text(command)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 2)
            } label: {
                Label {
                    Text(title)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
    }

    private func buildRows() {
        var taken = Set(existingGroups.map { $0.name.lowercased() })
        rows = result.groups.map { group in
            let name = Self.unique(group.name, taken: &taken)
            return PreviewRow(group: group, name: name, originalName: group.name)
        }
    }

    /// Re-derives final names from scratch against a fresh copy of `existingGroups`, rather than
    /// trusting `buildRows`' own suggestions still hold: a hand-edit after the sheet appeared can
    /// introduce a *new* collision — two rows renamed to the same thing, or a row renamed to exactly
    /// an existing group's name — that `buildRows` never saw. This is what makes "never overwrites an
    /// existing group without the rename" hold even against an adversarial or accidental edit, not
    /// just against the importer's own first guess.
    private func commit() {
        var taken = Set(existingGroups.map { $0.name.lowercased() })
        var renameNotes: [String] = []
        var finalGroups: [SnippetGroup] = []
        for row in rows {
            var group = row.group
            let trimmed = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let requested = trimmed.isEmpty ? row.originalName : trimmed
            let final = Self.unique(requested, taken: &taken)
            if final.lowercased() != row.originalName.lowercased() {
                renameNotes.append(String(localized: """
                    Group \u{201C}\(row.originalName)\u{201D} imported as \u{201C}\(final)\u{201D}.
                    """))
            }
            group.name = final
            finalGroups.append(group)
        }
        onCommit(finalGroups, renameNotes)
    }

    /// `name`, or `name (imported)`, `name (imported) 2`… when it is already spoken for in `taken`
    /// (which this always inserts into, so two incoming groups that started with the same name do not
    /// both get suggested the same rename).
    private static func unique(_ name: String, taken: inout Set<String>) -> String {
        guard taken.contains(name.lowercased()) else {
            taken.insert(name.lowercased())
            return name
        }
        var candidate = "\(name) (imported)"
        var suffix = 2
        while taken.contains(candidate.lowercased()) {
            candidate = "\(name) (imported) \(suffix)"
            suffix += 1
        }
        taken.insert(candidate.lowercased())
        return candidate
    }
}

/// Shown once an import has actually landed in the library: every line `EspansoImporter` reported
/// about what it could not map natively (kept verbatim for lossless re-export — see
/// `EspansoImporter`'s own doc comment), plus this app's own notes about renames and skipped-duplicate
/// globals. Selectable text throughout, since a line naming an exotic Espanso key is exactly the kind
/// of thing someone wants to copy into an issue or a note.
struct EspansoImportReportSheet: View {
    let lines: [String]
    let groupCount: Int
    let snippetCount: Int
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: lines.isEmpty ? "checkmark.circle.fill" : "info.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 34))
                    .foregroundStyle(lines.isEmpty ? Color.green : Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Import Complete").font(.headline)
                    Text("Added \(snippetCount) snippets in \(groupCount) groups.")
                        .foregroundStyle(.secondary)
                }
            }

            if !lines.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Notes on this import:")
                        .font(.callout)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(.callout, design: .monospaced))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 240)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
                    // The lines above are English whatever the app is running in: they name Espanso
                    // keys and YAML fragments, the file's own vocabulary, and half-translating them
                    // would read worse than saying so.
                    Text("These notes are written in English.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Done") { onDismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
