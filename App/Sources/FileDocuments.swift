import SwiftUI
import UniformTypeIdentifiers

/// A single Espanso match file on its way out through `.fileExporter` — `EspansoExporter.export`
/// already rendered it to YAML text; this only has to carry those bytes across the panel.
///
/// Read support exists because `FileDocument` requires it, not because anything in this app opens one
/// back through this type: Espanso import goes through `.fileImporter`, which hands back a `URL` this
/// app reads itself — see `EspansoTransfer.swift`.
struct YAMLDocument: FileDocument {
    static var readableContentTypes: [UTType] { [EspansoUTType.yml, EspansoUTType.yaml] }
    static var writableContentTypes: [UTType] { [EspansoUTType.yml] }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8)
        else { throw CocoaError(.fileReadCorruptFile) }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// A `ConfigBundle` on its way out through `.fileExporter` — `ConfigBundle.encode` already produced
/// the bytes this wraps. Same read-support note as `YAMLDocument` above: the Backup tab's restore
/// reads a picked file itself via `.fileImporter`, never through this type.
struct JSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    static var writableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
