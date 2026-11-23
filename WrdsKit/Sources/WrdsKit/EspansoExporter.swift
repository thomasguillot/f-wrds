import Foundation
import Yams

/// Writes native groups back out as Espanso match files.
///
/// This is `EspansoImporter` read backwards, and it inherits that side's contract: what the import
/// could not map was kept verbatim in `Snippet.unmapped`, and every one of those fragments is
/// grafted back under the key it was taken from. Import → export → import is the test that says so,
/// and it is the only test that can: the two halves are only correct with respect to each other.
///
/// The output is deterministic — the same group always gives the same bytes — because a config
/// file that churns is a config file nobody can keep in version control. Keys come out in Espanso's
/// own order, and kept keys, whose original position is not recorded, come out sorted at the end.
///
/// One rule runs through the whole emitter: **everything the user wrote is quoted, and only F Wrds'
/// own vocabulary is written bare**. A trigger of `no` or a value of `123` is a string, and quoting
/// it is what says so. Mapping *keys* are the exception — see `YAMLNode.key(_:)`.
public enum EspansoExporter {

    /// One group as one Espanso match file, with `globals` as its file-level `global_vars`.
    ///
    /// Never throws, and never refuses: a snippet Espanso itself would reject — a regex with a
    /// literal trigger kept beside it, say — is written out as it stands, because it is what the
    /// user's own file said and losing it would be the worse failure.
    ///
    /// What Espanso has no room for is left out rather than approximated. A group's `onlyInApps` and
    /// `neverInApps` are bundle identifiers, where Espanso filters on window titles and classes, and
    /// nothing here records that a group or a snippet is switched off. A switched-off snippet is
    /// still written: dropping it would delete the user's snippet from their own config, which is
    /// not what an export is for.
    public static func export(group: SnippetGroup, globals: [GlobalVariable]) -> String {
        var document: [(String, YAMLNode)] = [
            ("matches", .sequence(group.snippets.map { MatchWriter($0).node })),
        ]
        let variables = globals.compactMap { VariableWriter.node(for: $0.variable, graft: Graft()) }
        if !variables.isEmpty { document.append(("global_vars", .sequence(variables))) }
        return YAMLNode.mapping(document).lines.joined(separator: "\n") + "\n"
    }

    /// British in the API, American on the wire.
    static func wire(_ style: UppercaseStyle) -> String {
        switch style {
        case .capitalise: return "capitalize"
        case .capitaliseWords: return "capitalize_words"
        case .uppercase: return "uppercase"
        }
    }
}

// MARK: - Rendering

extension EspansoExporter {

    /// A YAML value on its way out.
    ///
    /// The tree carries *rendered* YAML rather than values, because half of what it carries was never a
    /// value here: a kept fragment is text that came out of Yams on the way in and goes back in as it
    /// is. Rendering by hand is what buys the 2-space block indentation Espanso's own files use —
    /// libyaml writes a list under a key at the key's own column, which is valid and reads as a
    /// diff-unfriendly surprise.
    enum YAMLNode {
        /// One line of YAML this exporter rendered itself.
        case scalar(String)
        /// A fragment kept from an import: YAML of a shape only the fragment knows.
        case text(String)
        /// Keys are rendered YAML too — see `key(_:)`.
        case mapping([(String, YAMLNode)])
        case sequence([YAMLNode])

        /// The lines this renders to, at no indentation. Empty for a value that is YAML's nothing.
        var lines: [String] {
            switch self {
            case .scalar(let text):
                return [text]
            case .text(let text):
                return Self.lines(ofFragment: text)
            case .mapping(let entries):
                return entries.isEmpty ? ["{}"] : entries.flatMap { Self.entry($0.0, $0.1) }
            case .sequence(let items):
                return items.isEmpty ? ["[]"] : items.flatMap(Self.item)
            }
        }

        private static func entry(_ key: String, _ value: YAMLNode) -> [String] {
            let lines = value.lines
            // A key with nothing under it: what the file said, and what re-parses to what it said.
            guard let first = lines.first else { return ["\(key):"] }
            if lines.count == 1, value.fitsAfterItsKey { return ["\(key): \(first)"] }
            return ["\(key):"] + lines.map { "  " + $0 }
        }

        /// A kept fragment's lines — or, when it no longer parses, the fragment as a quoted string.
        ///
        /// Nothing an import produces can fail here: every fragment came out of Yams and goes back
        /// in. One that has been edited by hand since then costs a single odd-looking value rather
        /// than a file Espanso cannot read at all, which is the difference between one snippet the
        /// user has to look at and a config that will not load.
        private static func lines(ofFragment text: String) -> [String] {
            if text.isEmpty { return [] }
            guard (try? Yams.compose(yaml: text)) != nil else { return [quoted(text)] }
            return text.components(separatedBy: "\n")
        }

        private static func item(_ node: YAMLNode) -> [String] {
            let lines = node.lines
            guard let first = lines.first else { return ["-"] }
            return ["- " + first] + lines.dropFirst().map { "  " + $0 }
        }

        /// Whether a one-line rendering may sit after its key.
        ///
        /// Only a scalar may. A kept fragment can be one line and still be a whole mapping or list —
        /// `from: a file`, `- "%H"` — and `k: from: a file` is not YAML at all, so the fragment is asked
        /// what it is rather than guessed at from its punctuation. It parsed on the way in, and the
        /// answer only matters for the handful of keys an import could not map.
        private var fitsAfterItsKey: Bool {
            switch self {
            case .scalar: return true
            case .text(let text):
                // A fragment that does not parse is written as a quoted string, which does fit.
                guard let node = try? Yams.compose(yaml: text) else { return true }
                return node.scalar != nil
            case .mapping(let entries): return entries.isEmpty
            case .sequence(let items): return items.isEmpty
            }
        }

        // MARK: Scalars

        /// Text the user wrote, double-quoted.
        ///
        /// The style is not decoration. Left to choose, libyaml writes a string with newlines in it as a
        /// *multi-line* quoted scalar, whose continuation lines are indented against a margin this
        /// emitter has already moved — and every second snippet has a newline in it. Double-quoted is
        /// the one style that always fits on one line, and it is what Espanso's own files use.
        static func string(_ value: String) -> YAMLNode { .scalar(quoted(value)) }

        /// A word from Espanso's vocabulary, or a number: written bare, because it is not text.
        static func plain(_ value: String) -> YAMLNode { .scalar(value) }

        /// A mapping key as YAML: bare where it can be, quoted where it cannot.
        ///
        /// Bare is not merely tidier here, it is safer. Quoting tags a scalar as a string, and the
        /// importer looks a form field up by a key it composes implicitly — to Yams a quoted `"no"` and
        /// a bare `no` are different nodes, and the lookup would miss. Since a key is only ever read
        /// back as text, leaving it bare costs nothing and keeps both sides implicit.
        static func key(_ name: String) -> String {
            let plain = name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_-.".contains($0)) }
            guard plain, let first = name.first, first != "-", first != "." else { return quoted(name) }
            return name
        }

        private static func quoted(_ value: String) -> String {
            YAMLFragment.text(from: .scalar(.init(value, .implicit, .doubleQuoted)))
        }
    }

    // MARK: Where a kept fragment goes back

    /// The fragments kept from one thing, arranged the way they graft back on.
    ///
    /// `Snippet.unmapped` is flat — `var:pick.values.0.id` is one key — but what it describes is a tree,
    /// and putting a fragment back means walking it: `values` names a parameter, `0` an element of it,
    /// `id` a key of that element. Splitting once here is what lets every writer below ask only about
    /// its own level.
    struct Graft {
        /// Fragments that belong straight under this level, by key.
        private(set) var direct: [String: String] = [:]
        /// Fragments belonging to something nested under one of this level's keys.
        private(set) var nested: [String: Graft] = [:]

        init() {}

        init(_ fragments: [(path: String, fragment: String)]) {
            for (path, fragment) in fragments {
                insert(path.split(separator: ".").map(String.init)[...], fragment)
            }
        }

        private mutating func insert(_ path: ArraySlice<String>, _ fragment: String) {
            guard let head = path.first else { return }
            guard path.count > 1 else { return direct[head] = fragment }
            var child = nested[head] ?? Graft()
            child.insert(path.dropFirst(), fragment)
            nested[head] = child
        }

        /// `generated`, with every entry a kept fragment can speak for replaced by that fragment, and
        /// every fragment with no entry of its own appended in sorted order.
        ///
        /// The fragment wins because the model only ever holds a value beside one where it could not
        /// hold the value at all: an unreadable `values:` left an empty picker behind, and writing that
        /// empty picker back would be the one place the import stopped being lossless.
        ///
        /// `claimed` names the keys whose *nested* fragments the caller has already put back — the
        /// `values` of a picker, the `fields` of a form. Everything nested under any other key is
        /// written here instead of being dropped, under the dotted name it was kept as, which is the
        /// name a re-import gives it again. This is the last resort of the whole exporter, and the
        /// keys reaching it are unreachable from an import: every path an import writes is nested
        /// under a parameter one of the writers above claims.
        func applied(to generated: [(String, YAMLNode)],
                     consuming claimed: Set<String> = []) -> [(String, YAMLNode)] {
            let written = Set(generated.map(\.0))
            var entries = generated.map { key, node in
                (YAMLNode.key(key), direct[key].map(YAMLNode.text) ?? node)
            }
            entries += direct.sorted { $0.key < $1.key }
                .filter { !written.contains($0.key) }
                .map { (YAMLNode.key($0.key), YAMLNode.text($0.value)) }
            entries += nested.sorted { $0.key < $1.key }
                .filter { !claimed.contains($0.key) }
                .flatMap { $0.value.flattened(under: $0.key) }
                .map { (YAMLNode.key($0.path), YAMLNode.text($0.fragment)) }
            return entries
        }

        /// Every fragment at this level and below, back under the dotted path it was kept as.
        private func flattened(under prefix: String) -> [(path: String, fragment: String)] {
            direct.sorted { $0.key < $1.key }.map { ("\(prefix).\($0.key)", $0.value) }
                + nested.sorted { $0.key < $1.key }
                    .flatMap { $0.value.flattened(under: "\(prefix).\($0.key)") }
        }
    }
}

// MARK: - One match

extension EspansoExporter {

    /// Writes one snippet as one Espanso match.
    struct MatchWriter {

        /// What `Snippet.unmapped` prefixes a variable's fragments with.
        private static let variablePrefix = "var:"

        /// The keys Espanso reads as a match's body. A snippet with no content of its own but one of
        /// these kept beside it already has a body, and must not be handed an empty `replace` too.
        private static let bodyKeys: Set<String> = ["form", "html", "markdown", "image_path"]

        private let snippet: Snippet
        /// Fragments under a literal match key, and any whose variable is gone (see `init`).
        private let keys: [String: String]
        /// Fragments belonging to a variable that is still here, by its name.
        private let variables: [String: Graft]
        /// Variables of a type F Wrds never mapped, kept whole and written back whole.
        private let wholeVariables: [(name: String, fragment: String)]

        init(_ snippet: Snippet) {
            self.snippet = snippet
            let named = Set(snippet.variables.map(\.name))
            var keys: [String: String] = [:]
            var paths: [String: [(path: String, fragment: String)]] = [:]
            var whole: [(name: String, fragment: String)] = []
            for (key, fragment) in snippet.unmapped.sorted(by: { $0.key < $1.key }) {
                guard key.hasPrefix(Self.variablePrefix) else { keys[key] = fragment; continue }
                let rest = String(key.dropFirst(Self.variablePrefix.count))
                let name = String(rest.prefix { $0 != "." })
                if name == rest {
                    whole.append((name, fragment))
                } else if named.contains(name) {
                    paths[name, default: []].append((String(rest.dropFirst(name.count + 1)), fragment))
                } else {
                    // A fragment whose variable is no longer in the snippet. Written under its own
                    // name rather than dropped: it re-imports under the key it has now, which keeps
                    // the data even though its home is gone.
                    keys[key] = fragment
                }
            }
            self.keys = keys
            self.variables = paths.mapValues(Graft.init)
            // In the order they stood in, so putting them back is a walk rather than a search.
            self.wholeVariables = whole.sorted {
                (Self.position(of: $0.name) ?? .max, $0.name)
                    < (Self.position(of: $1.name) ?? .max, $1.name)
            }
        }

        /// Where a variable kept whole stood in the file, when its key still says: an unnamed one is
        /// kept under `var:#<n>`, and that `n` is its place in the list.
        private static func position(of name: String) -> Int? {
            guard name.hasPrefix("#"), let place = Int(name.dropFirst()), place > 0 else { return nil }
            return place - 1
        }

        /// The match, keys in Espanso's own order, kept keys sorted at the end.
        var node: YAMLNode {
            let shorthand = shorthandForm
            var entries = triggers
            if let regex = snippet.regexTrigger { entries.append(("regex", .string(regex))) }
            if !snippet.label.isEmpty { entries.append(("label", .string(snippet.label))) }
            entries += shorthand ?? body
            if snippet.wordBoundary { entries.append(("word", .plain("true"))) }
            if snippet.propagateCase { entries.append(("propagate_case", .plain("true"))) }
            if let style = snippet.uppercaseStyle {
                entries.append(("uppercase_style", .plain(EspansoExporter.wire(style))))
            }
            if let list = variableList(formIsShorthand: shorthand != nil) {
                entries.append(("vars", list))
            }
            // A kept key wins over anything generated under the same name, for the reason
            // `Graft.applied(to:)` gives: where one exists, the model could not hold the value.
            return .mapping(entries.filter { keys[$0.0] == nil } + kept)
        }

        private var triggers: [(String, YAMLNode)] {
            switch snippet.triggers.count {
            case 0: return []
            case 1: return [("trigger", .string(snippet.triggers[0]))]
            default: return [("triggers", .sequence(snippet.triggers.map(YAMLNode.string)))]
            }
        }

        private var body: [(String, YAMLNode)] {
            if !snippet.content.isEmpty { return [("replace", .string(snippet.content))] }
            // Nothing to type, and nothing kept that Espanso would type instead: an empty body still
            // has to be written, or the match is not a match.
            return keys.keys.contains(where: Self.bodyKeys.contains) ? [] : [("replace", .string(""))]
        }

        /// The match-level `form:`, when this snippet is one.
        ///
        /// The shorthand is the spelling where the layout *is* the content, so it can only be
        /// written back when the content is exactly what the layout would lay out — every field
        /// named, in order, and nothing between them that Espanso would read as a placeholder. When
        /// it is not, the form goes out as a `type: form` variable instead, which says the same
        /// thing with the content left alone.
        ///
        /// It is refused for one more reason: the shorthand has no `params:` to put things under, so
        /// a form with anything kept against it beyond its fields — a layout kept for its wording,
        /// most likely — has to go out as the variable it was, which is the only spelling with
        /// somewhere to put it.
        private var shorthandForm: [(String, YAMLNode)]? {
            let name = EspansoImporter.shorthandFormName
            let graft = variables[name] ?? Graft()
            guard keys["form"] == nil, keys["form_fields"] == nil, snippet.variables.count == 1,
                  graft.direct.isEmpty, graft.nested.keys.allSatisfy({ $0 == "fields" }),
                  let variable = snippet.variables.first, variable.name == name,
                  case .form(let fields) = variable.kind,
                  let layout = VariableWriter.layout(of: fields, in: snippet.content, named: name)
            else { return nil }
            var entries: [(String, YAMLNode)] = [("form", .string(layout))]
            if let spec = VariableWriter.fields(fields, namedIn: layout,
                                                graft: graft.nested["fields"] ?? Graft()) {
                entries.append(("form_fields", spec))
            }
            return entries
        }

        /// The `vars:` list: the variables that mapped, in the order they are held in, with the ones
        /// that never mapped put back where they stood.
        ///
        /// Position matters for an unnamed one, whose key *is* its position (`var:#2`): appended to
        /// the end it would come back under a different key, which is a fragment lost by another
        /// name. One whose place is not recorded — a named variable of a type F Wrds cannot read —
        /// goes on the end, since nothing about it says otherwise.
        private func variableList(formIsShorthand: Bool) -> YAMLNode? {
            var items: [YAMLNode] = formIsShorthand ? [] : snippet.variables.compactMap {
                VariableWriter.node(for: $0, graft: variables[$0.name] ?? Graft())
            }
            for whole in wholeVariables {
                guard let place = Self.position(of: whole.name), place <= items.count else {
                    items.append(.text(whole.fragment))
                    continue
                }
                items.insert(.text(whole.fragment), at: place)
            }
            return items.isEmpty ? nil : .sequence(items)
        }

        private var kept: [(String, YAMLNode)] {
            keys.sorted { $0.key < $1.key }.map { (YAMLNode.key($0.key), YAMLNode.text($0.value)) }
        }
    }
}
