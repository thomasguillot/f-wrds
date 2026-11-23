import Foundation
import Yams

/// What one import produced: groups to add, globals to merge, and a list of everything that could
/// not be expressed natively.
///
/// The report is not an error log. Every line in it describes something that *was* kept — the
/// import succeeded, and this is what the user should be told about the parts of their config F
/// Wrds cannot yet act on.
public struct EspansoImportResult: Sendable {
    /// One per match file, named after the file's stem, in the order the files were given.
    public var groups: [SnippetGroup]
    /// Every file's `global_vars`, in the order they were read.
    public var globals: [GlobalVariable]
    /// Human-readable lines, in the order the things they describe were met.
    public var unmappedReport: [String]

    public init(groups: [SnippetGroup] = [], globals: [GlobalVariable] = [],
                unmappedReport: [String] = []) {
        self.groups = groups
        self.globals = globals
        self.unmappedReport = unmappedReport
    }
}

/// Why an import refused to happen *at all*.
///
/// There is no partial import: a file the user picked that turns out to be broken fails the whole
/// operation, so the library is never left holding half a migration. Content that cannot be mapped
/// is not an error — that is what `EspansoImportResult.unmappedReport` is for.
public enum EspansoImportError: Error, Equatable, Sendable {
    /// Not a YAML file. The caller passes explicit URLs, so this is a mistake on its side.
    case notAMatchFile(URL)
    /// Missing, unreadable, or not UTF-8.
    case unreadable(URL)
    /// Not valid YAML, or valid YAML that is not shaped like an Espanso match file.
    case malformed(file: String, reason: String)
}

/// Reads Espanso match files into native groups, keeping everything it cannot map.
///
/// Espanso is the migration path into F Wrds, so the importer's contract is *losslessness* rather
/// than best effort: a key it does not understand is serialised back to YAML and parked in
/// `Snippet.unmapped` under its own name, and a variable type it does not understand is parked
/// whole. Nothing is dropped silently, everything parked is named in the report, and the exporter
/// can put all of it back where it came from.
///
/// The reading itself is split by scale: this type does files, `FileReader` does one file's matches
/// and globals, `MatchReader` does one match, and `VariableReader` does the variables inside it.
public enum EspansoImporter {

    /// The budget given to every imported shell variable.
    ///
    /// Espanso has no per-variable timeout, so one has to be invented, and it has to be a number
    /// `ShellRunner` treats as a real deadline: past roughly a century it waits forever, and at zero
    /// or below it kills the command before it starts. Ten seconds is long enough for a `git` call
    /// on a cold cache and short enough that a hung command is a `⚠︎` rather than a frozen app.
    static let shellTimeoutSeconds = 10.0

    /// Used when a date variable arrives without a `format`, which Espanso allows and the renderer
    /// does not. Reported, because it is a guess at what the author meant.
    static let fallbackDateFormat = "%Y-%m-%d"

    /// The name given to the variable synthesised from a match-level `form:`, and so the prefix its
    /// answers are read back under: `{{form.<field>}}`.
    static let shorthandFormName = "form"

    /// Reads every file, or throws having produced nothing.
    ///
    /// Files are parsed in the order given and the whole result is built before returning, so a
    /// malformed fifth file cannot leave the first four applied.
    public static func importFiles(_ urls: [URL]) throws -> EspansoImportResult {
        var result = EspansoImportResult()
        var taken: Set<String> = []
        for url in urls {
            let name = url.lastPathComponent
            guard ["yml", "yaml"].contains(url.pathExtension.lowercased()) else {
                throw EspansoImportError.notAMatchFile(url)
            }
            let stem = url.deletingPathExtension().lastPathComponent
            // Espanso reserves a leading underscore for files that are not match files — package
            // manifests, mostly. Skipping them is right; skipping them silently is not, because the
            // user is the one who selected them.
            guard !stem.hasPrefix("_") else {
                result.unmappedReport.append("\(name): skipped, not an Espanso file")
                continue
            }
            var reader = FileReader(file: name)
            let group = unique(stem, taken: &taken)
            if group != stem {
                reader.report.append("\(name): imported as group '\(group)': "
                    + "a group named '\(stem)' was already imported")
            }
            let read = try reader.read(text(of: url), groupName: group)
            result.groups.append(read.group)
            result.globals += read.globals
            result.unmappedReport += reader.report
        }
        return result
    }

    /// Espanso's own match directory, if this machine has one.
    public static func defaultEspansoMatchDirectory() -> URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/espanso/match", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return url
    }

    /// A file's text, or `.unreadable`. The failable UTF-8 decode is the point: a file that is not
    /// text is a file the user picked by mistake, and reading it with replacement characters would
    /// turn that mistake into a library full of mojibake.
    private static func text(of url: URL) throws -> String {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { throw EspansoImportError.unreadable(url) }
        return text
    }

    /// Whether a value is YAML's nothing: a key written with nothing under it (`matches:`), an
    /// explicit `null`, or a `~`.
    ///
    /// Espanso configs are full of stub files and half-written sections, and a section with nothing
    /// in it is nothing rather than a fault — failing there would take a whole directory's migration
    /// down with it. A section of the *wrong* type still throws: that is a broken file, not an empty
    /// one.
    static func isEmpty(_ node: Node) -> Bool {
        node.null != nil
    }

    /// `name`, or `name 2`, `name 3`… when it is already spoken for — importing `base.yml` from two
    /// packages must not merge them into one group.
    private static func unique(_ name: String, taken: inout Set<String>) -> String {
        var candidate = name
        var suffix = 2
        while taken.contains(candidate) {
            candidate = "\(name) \(suffix)"
            suffix += 1
        }
        taken.insert(candidate)
        return candidate
    }
}

// MARK: - What could not be mapped

extension EspansoImporter {

    /// Something that could not be mapped, and where it is being kept.
    struct KeptFragment {
        /// The key it goes under in `Snippet.unmapped`.
        let key: String
        /// Its YAML, verbatim.
        let fragment: String
        /// The tail of the report line describing it.
        let note: String
    }

    /// A variable as far as it could be mapped, plus everything about it that could not be.
    struct ParsedVariable {
        var variable: Variable?
        /// A `type: form` layout, which the content has to have inlined into it.
        var layout: String?
        var kept: [KeptFragment] = []
        /// Report lines for things that changed but were not kept, like a defaulted date format.
        var notes: [String] = []
    }

    // MARK: One file

    /// Reads one match file into a group, accumulating report lines as it goes.
    struct FileReader {

        let file: String
        var report: [String] = []

        mutating func read(_ text: String, groupName: String)
            throws -> (group: SnippetGroup, globals: [GlobalVariable]) {
            let root: Node?
            do {
                root = try Yams.compose(yaml: text)
            } catch {
                throw malformed(String(describing: error))
            }
            // An empty file, or one that is nothing but comments, is an empty group rather than a
            // fault: Espanso users keep placeholder files around.
            guard let root else { return (SnippetGroup(name: groupName), []) }
            guard let mapping = root.mapping else { throw malformed("the root must be a mapping") }

            var snippets: [Snippet] = []
            var globals: [GlobalVariable] = []
            for (keyNode, value) in mapping {
                guard let key = keyNode.string else { throw malformed("keys must be strings") }
                switch key {
                case "matches":
                    snippets = try self.snippets(from: value)
                case "global_vars":
                    globals = try globalVariables(from: value)
                default:
                    // A group has nowhere to park raw YAML — only snippets do — so `filter_title`
                    // and friends can only be named. That still beats a silent drop.
                    report.append("\(file): dropped unsupported top-level key '\(key)'")
                }
            }
            return (SnippetGroup(name: groupName, snippets: snippets), globals)
        }

        private mutating func snippets(from node: Node) throws -> [Snippet] {
            guard let list = node.sequence else {
                guard EspansoImporter.isEmpty(node) else { throw malformed("`matches` must be a list") }
                return []
            }
            var snippets: [Snippet] = []
            for (index, entry) in list.enumerated() {
                guard let mapping = entry.mapping else {
                    throw malformed("match #\(index + 1) must be a mapping")
                }
                var reader = MatchReader(file: file, mapping: mapping, index: index)
                snippets.append(try reader.read())
                report += reader.report
            }
            return snippets
        }

        private mutating func globalVariables(from node: Node) throws -> [GlobalVariable] {
            guard let list = node.sequence else {
                guard EspansoImporter.isEmpty(node) else {
                    throw malformed("`global_vars` must be a list")
                }
                return []
            }
            var globals: [GlobalVariable] = []
            for (index, entry) in list.enumerated() {
                let parsed = try VariableReader.parse(entry, index: index, in: file)
                // A global is a variable with nowhere to park raw YAML, so what a snippet would keep
                // is only reported here.
                for kept in parsed.kept { report.append("\(file) › global_vars: dropped \(kept.note)") }
                for note in parsed.notes { report.append("\(file) › global_vars: \(note)") }
                if let variable = parsed.variable { globals.append(GlobalVariable(variable: variable)) }
            }
            return globals
        }

        private func malformed(_ reason: String) -> EspansoImportError {
            .malformed(file: file, reason: reason)
        }
    }
}

// MARK: - Raw YAML

/// A YAML node, back as the text it came from.
///
/// Shared with the exporter, which parses these fragments to put unmapped keys back. Emitted with
/// no line folding and no escaping of non-ASCII, so what comes out is what a person wrote — and,
/// re-parsed, is the node that went in: a quoted `"true"` stays a string, a bare `true` stays a
/// boolean, and a block scalar keeps its lines.
enum YAMLFragment {
    static func text(from node: Node) -> String {
        guard let serialised = try? Yams.serialize(node: node, width: -1, allowUnicode: true) else {
            return node.string ?? ""
        }
        return serialised.hasSuffix("\n") ? String(serialised.dropLast()) : serialised
    }
}
