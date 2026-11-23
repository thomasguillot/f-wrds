import AppKit
import UniformTypeIdentifiers
import WrdsKit

/// Espanso's own YAML dialect — used both to filter the import pickers and as every exported file's
/// content type. Declared dynamically rather than registered as an exported/imported type in
/// `Info.plist`: this app only ever *writes* `.yml` (or reads files the user explicitly picked), never
/// claims ownership of the extension on the system, so no UTI declaration belongs there.
enum EspansoUTType {
    static let yml = UTType(filenameExtension: "yml", conformingTo: .plainText) ?? .plainText
    static let yaml = UTType(filenameExtension: "yaml", conformingTo: .plainText) ?? .plainText
}

/// Turns a group name into a filesystem-safe `.yml` stem, unique against everything already written
/// in the same export. Shared between `AppModel.exportToEspanso()` and `GroupsSidebarView`'s per-group
/// "Export…", so the two name files exactly the same way.
enum EspansoFilename {
    static func unique(_ name: String, taken: inout Set<String>) -> String {
        let base = sanitized(name)
        var candidate = base
        var suffix = 2
        while taken.contains(candidate.lowercased()) {
            candidate = "\(base) \(suffix)"
            suffix += 1
        }
        taken.insert(candidate.lowercased())
        return candidate
    }

    /// Strips characters a filesystem would choke on. `/` above all — a group name is free text and
    /// routinely contains one (`"Work/Personal"`); `:` too, since Finder still translates a literal
    /// colon in a filename into a `/` behind the scenes, which would otherwise silently rewrite the
    /// group's own name into a path.
    static func sanitized(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Untitled" : cleaned
    }
}

/// An Espanso import that has been read but not yet added, waiting on the preview sheet.
struct PendingEspansoImport: Identifiable {
    let id = UUID()
    let result: EspansoImportResult
}

/// What a finished import added, and anything worth knowing about how.
struct EspansoImportSummary: Identifiable {
    let id = UUID()
    let lines: [String]
    let groupCount: Int
    let snippetCount: Int
}

/// Import and export, started from the menu bar menu, the File menu or the empty library.
///
/// Import reads the files straight away and parks the result in `pendingEspansoImport`, which
/// `MainWindowView` presents as a preview: nothing reaches the library until the user confirms
/// there, because that preview is where incoming shell commands are disclosed.
extension AppModel {
    func startEspansoImport() {
        guard canEditSnippets else { return }
        if let directory = EspansoImporter.defaultEspansoMatchDirectory() {
            let files = Self.espansoMatchFiles(in: directory)
            if !files.isEmpty {
                loadEspansoImport(files)
                return
            }
        }
        let panel = NSOpenPanel()
        panel.message = String(localized: "Choose your Espanso folder, or one or more .yml files.")
        panel.prompt = String(localized: "Import")
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [EspansoUTType.yml, EspansoUTType.yaml, .folder]
        guard panel.runModal() == .OK else { return }
        let files = panel.urls.flatMap { url -> [URL] in
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return isDirectory ? Self.espansoMatchFiles(in: url) : [url]
        }
        guard !files.isEmpty else {
            Self.showAlert(String(localized: "Nothing to Import"),
                           String(localized: "No Espanso files (.yml or .yaml) were found there."))
            return
        }
        loadEspansoImport(files)
    }

    /// Adds the groups the preview confirmed, then hands `MainWindowView` a summary to show. No
    /// summary when the write failed: `storeFailure` already says why, and a report on top of it
    /// would read as a success.
    func commitEspansoImport(groups: [SnippetGroup], globals: [GlobalVariable], notes: [String]) {
        let result = importLibrary(groups: groups, globals: globals)
        guard result.succeeded else { return }
        let skipped = result.skippedGlobalNames.map {
            String(localized: """
                The global variable \u{201C}\($0)\u{201D} was skipped because you already have one \
                with that name. Imported snippets use your existing value.
                """)
        }
        espansoImportSummary = EspansoImportSummary(
            lines: notes + skipped, groupCount: groups.count,
            snippetCount: groups.reduce(0) { $0 + $1.snippets.count })
    }

    func exportToEspanso() {
        guard !groups.isEmpty else {
            Self.showAlert(String(localized: "Nothing to Export"),
                           String(localized: "Add a group with some snippets first."))
            return
        }
        let panel = NSOpenPanel()
        panel.message = String(localized: """
            Choose a folder for the Espanso files, one per group. App filters and on/off \
            switches aren't included. For a complete copy, use Export Backup in Settings.
            """)
        panel.prompt = String(localized: "Export Here")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let directory = panel.url else { return }

        var taken: Set<String> = []
        var failures: [String] = []
        for group in groups {
            let text = EspansoExporter.export(group: group, globals: globals)
            let filename = EspansoFilename.unique(group.name, taken: &taken) + ".yml"
            do {
                try Data(text.utf8).write(to: directory.appendingPathComponent(filename), options: .atomic)
            } catch {
                failures.append(group.name)
            }
        }
        if failures.isEmpty {
            Self.showAlert(String(localized: "Export Complete"),
                           String(localized: "Exported \(groups.count) groups to \(directory.lastPathComponent)."))
        } else {
            Self.showAlert(String(localized: "Export Incomplete"),
                           String(localized: "Couldn't write: \(failures.joined(separator: ", "))."))
        }
    }

    private func loadEspansoImport(_ files: [URL]) {
        do {
            let result = try EspansoImporter.importFiles(files)
            guard !result.groups.isEmpty else {
                Self.showAlert(String(localized: "Nothing to Import"),
                               String(localized: "No snippets were found in your Espanso files."))
                return
            }
            pendingEspansoImport = PendingEspansoImport(result: result)
        } catch let error as EspansoImportError {
            Self.showAlert(String(localized: "Couldn't Import"), Self.describe(error))
        } catch {
            Self.showAlert(String(localized: "Couldn't Import"), error.localizedDescription)
        }
    }

    private static func espansoMatchFiles(in directory: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return items
            .filter { ["yml", "yaml"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private static func describe(_ error: EspansoImportError) -> String {
        switch error {
        case .notAMatchFile(let url):
            return String(localized: "\(url.lastPathComponent) isn't an Espanso file (.yml or .yaml).")
        case .unreadable(let url):
            return String(localized: "\(url.lastPathComponent) couldn't be read.")
        case .malformed(let file, let reason):
            return String(localized: "\(file) isn't a valid Espanso file: \(reason).")
        }
    }

    private static func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
