import SwiftUI
import UniformTypeIdentifiers
import WrdsKit

/// Whole-config export/import via `ConfigBundle` — the actual backup format, as opposed to
/// the Espanso import and export (`EspansoTransfer.swift`), which is a migration path and says so in its own copy.
struct BackupSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    @State private var exportDocument = JSONDocument(data: Data())
    @State private var isExporting = false
    @State private var exportError: String?

    @State private var isImporting = false
    @State private var importError: String?
    @State private var pendingRestore: ConfigBundle?
    @State private var showsRestoreConfirmation = false
    /// Guards the confirmation's self-clearing `Task` against a second restore racing the first's —
    /// the same shape as `AppModel.formFailure`/`formFailureToken`, for the same reason: without it, a
    /// stale timer from an earlier restore could clear a newer confirmation it had no idea existed.
    @State private var restoreConfirmationToken: UUID?

    var body: some View {
        Form {
            Section("Back Up") {
                Text("""
                    Saves every group, snippet, global variable and setting to one file. Use it to \
                    move to a new Mac or to go back later.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Export Backup\u{2026}") { beginExport() }
                    .disabled(!canBackUp)
                if let exportError {
                    Text(exportError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Section("Restore") {
                Text("Replaces everything in F Wrds with the contents of a backup file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Restore Backup\u{2026}") { isImporting = true }
                    .disabled(!canBackUp)
                if showsRestoreConfirmation {
                    Text("Restored.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let importError {
                    Text(importError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Section("Espanso") {
                Text("""
                    Import your snippets from Espanso, or export them as Espanso files. Exports \
                    leave out app filters and on/off switches. Use Export Backup for a complete copy.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Import from Espanso\u{2026}") {
                        openWindow(id: "manager")
                        model.startEspansoImport()
                    }
                    .disabled(!model.canEditSnippets)
                    Button("Export to Espanso\u{2026}") { model.exportToEspanso() }
                }
            }
            if !canBackUp {
                Text("Backup and restore are off because F Wrds can't read your library or settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fileExporter(isPresented: $isExporting, document: exportDocument, contentType: .json,
                      defaultFilename: "F Wrds Backup") { result in
            if case .failure(let error) = result {
                exportError = String(localized: "Couldn't save the backup: \(error.localizedDescription)")
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            handleImportPick(result)
        }
        .confirmationDialog(
            "Restore this backup?",
            isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
            titleVisibility: .visible
        ) {
            Button("Restore", role: .destructive) { confirmRestore() }
            Button("Cancel", role: .cancel) { pendingRestore = nil }
        } message: {
            Text("""
                Restoring replaces all snippets, groups, global variables and settings. This can't be \
                undone.
                """)
        }
    }

    /// Backing up reads `model.groups`/`model.globals`/`model.settings` straight from memory, which
    /// only reflects what is truly on disk once both stores have actually loaded — exporting before
    /// that would back up a build's in-memory defaults as if they were the user's real
    /// configuration. Restoring is gated the same way for the mirror-image reason: `AppModel.restore
    /// (from:)` still ultimately checks each store's own `notLoaded` gate, but refusing here gives a
    /// clearer reason than letting the click through to a `storeFailure` after the fact.
    private var canBackUp: Bool { model.canEditSnippets && model.canEditSettings }

    private func beginExport() {
        exportError = nil
        do {
            let data = try ConfigBundle.encode(groups: model.groups, globals: model.globals,
                                               settings: model.settings)
            exportDocument = JSONDocument(data: data)
            isExporting = true
        } catch {
            // `ConfigBundle.encode` only throws for a shell variable's non-finite timeout — JSON has
            // no spelling for one and `JSONEncoder` refuses rather than inventing one. Naming the
            // failure this plainly, rather than the raw `EncodingError`, is what actually points the
            // user at which snippet to fix.
            exportError = String(localized: """
                Couldn't prepare the backup. One of your snippets has an invalid value: \
                \(error.localizedDescription)
                """)
        }
    }

    private func handleImportPick(_ result: Result<URL, Error>) {
        importError = nil
        switch result {
        case .failure(let error):
            importError = error.localizedDescription
        case .success(let url):
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                pendingRestore = try ConfigBundle.decode(data)
            } catch let error as ConfigBundle.ImportError {
                importError = Self.describe(error)
            } catch {
                importError = String(localized: "Couldn't read that file: \(error.localizedDescription)")
            }
        }
    }

    private func confirmRestore() {
        guard let bundle = pendingRestore else { return }
        pendingRestore = nil
        // A failed restore already has `StoreFailureBanner` above the tabs saying why — this is only
        // ever the *positive* case, so there is nothing else to show on failure. Absence of a banner
        // is not itself feedback, which is the whole reason this exists rather than leaving a
        // successful restore to be inferred from nothing changing on screen.
        guard model.restore(from: bundle) else { return }
        let token = UUID()
        restoreConfirmationToken = token
        showsRestoreConfirmation = true
        Task {
            try? await Task.sleep(for: .seconds(3))
            if restoreConfirmationToken == token { showsRestoreConfirmation = false }
        }
    }

    private static func describe(_ error: ConfigBundle.ImportError) -> String {
        switch error {
        case .malformed:
            return String(localized: "That file doesn't look like an F Wrds backup.")
        case .unsupportedVersion(let version):
            return String(localized: """
                This backup was made by a newer version of F Wrds (file format \(version)). Update F \
                Wrds and try again.
                """)
        }
    }
}
