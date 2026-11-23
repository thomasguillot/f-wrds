import Foundation
import Yams

// One Espanso match: its keys, and the shape of the snippet they make. Second of the three scales
// the importer reads at — file, match, variable — split up so that no one of them has to be read to
// understand another.

extension EspansoImporter {

    // MARK: - One match

    /// Reads one `matches:` entry into a snippet.
    struct MatchReader {

        let file: String
        /// How this match is named in the report: whatever the user would recognise it by.
        let match: String
        private let mapping: Node.Mapping
        private var snippet = Snippet()
        private(set) var report: [String] = []

        init(file: String, mapping: Node.Mapping, index: Int) {
            self.file = file
            self.mapping = mapping
            self.match = Self.identifier(of: mapping, index: index)
        }

        mutating func read() throws -> Snippet {
            // Read ahead: both of these decide what *other* keys mean, and YAML keys arrive in
            // whatever order they were written in.
            let regex = Self.text(mapping["regex"])
            let shorthand = Self.text(mapping["form"])
            snippet.regexTrigger = regex
            var parsed: [ParsedVariable] = []

            for (keyNode, value) in mapping {
                guard let key = keyNode.string else { throw malformed("keys must be strings") }
                switch key {
                case "regex", "form":
                    // Both were read before the loop. A value neither could read — a list, or a key
                    // with nothing under it — is kept here rather than passed over in silence.
                    keepUnreadable(key, value)
                case "trigger", "triggers":
                    // Espanso does not allow a regex and a literal trigger together either. The
                    // regex wins because it is the more specific of the two, and the trigger is kept
                    // rather than dropped on the way past.
                    if regex == nil {
                        snippet.triggers += Self.strings(value)
                    } else {
                        keep(key, value, note: "'\(key)' alongside 'regex'; the regex wins")
                    }
                case "replace":
                    if shorthand != nil {
                        keep(key, value, note: "'replace' alongside 'form'; the form wins")
                    } else if let text = value.string {
                        snippet.content = text
                    } else {
                        keep(key, value, note: "unsupported value for 'replace'")
                    }
                case "form_fields":
                    // Only meaningful next to a `form:`; alone it types fields nothing asks for.
                    if shorthand == nil { keep(key, value, note: "unsupported key '\(key)'") }
                case "label":
                    if let text = value.string { snippet.label = text } else { keepValue(key, value) }
                case "word":
                    if let flag = value.bool { snippet.wordBoundary = flag } else { keepValue(key, value) }
                case "propagate_case":
                    if let flag = value.bool { snippet.propagateCase = flag } else { keepValue(key, value) }
                case "uppercase_style":
                    if let style = Self.uppercaseStyle(value.string) {
                        snippet.uppercaseStyle = style
                    } else {
                        keep(key, value, note: "unsupported uppercase style '\(value.string ?? "")'")
                    }
                case "vars":
                    parsed = try variables(from: value)
                default:
                    keep(key, value, note: "unsupported key '\(key)'")
                }
            }
            finish(parsed: parsed, shorthand: shorthand)
            return snippet
        }

        /// Folds the variables into the snippet, and the form layouts into its content.
        ///
        /// Both forms of form end up in the same shape: fields answered under a variable's name, and
        /// a layout inlined where the content referred to it — `{{details}}` becomes the layout with
        /// each `[[ticket]]` rewritten as `{{details.ticket}}`, which is what the renderer reads. A
        /// match-level `form:` is the same thing with the layout *as* the content and the name
        /// `form`.
        private mutating func finish(parsed: [ParsedVariable], shorthand: String?) {
            var variables: [Variable] = []
            for entry in parsed {
                for kept in entry.kept { keep(kept) }
                for note in entry.notes { report.append("\(file) › \(match): \(note)") }
                guard let variable = entry.variable else { continue }
                variables.append(variable)
                guard let layout = entry.layout else { continue }
                let inlined = VariableReader.inliningFields(of: layout, into: variable.name)
                snippet.content = VariableReader.inlining(inlined, of: variable.name,
                                                          into: snippet.content)
            }
            if let shorthand {
                let name = EspansoImporter.shorthandFormName
                let form = VariableReader.formFields(layout: shorthand,
                                                     spec: mapping["form_fields"]?.mapping,
                                                     variable: name)
                snippet.content = VariableReader.inliningFields(of: shorthand, into: name)
                variables.append(Variable(name: name, kind: .form(fields: form.fields)))
                for kept in form.kept { keep(kept) }
            }
            snippet.variables = variables
        }

        private func variables(from node: Node) throws -> [ParsedVariable] {
            guard let list = node.sequence else {
                guard EspansoImporter.isEmpty(node) else { throw malformed("`vars` must be a list") }
                return []
            }
            return try list.enumerated().map {
                try VariableReader.parse($0.element, index: $0.offset, in: file)
            }
        }

        // MARK: Naming and small conversions

        private static func identifier(of mapping: Node.Mapping, index: Int) -> String {
            if let trigger = mapping["trigger"]?.string { return trigger }
            if let first = mapping["triggers"]?.sequence?.first?.string { return first }
            if let regex = mapping["regex"]?.string { return regex }
            if let label = mapping["label"]?.string, !label.isEmpty { return label }
            return "match #\(index + 1)"
        }

        /// A scalar's text, or `nil` for a value that is not one — a list, a mapping, or a key
        /// written with nothing under it. Empty counts as nothing: `regex:` with no pattern is not a
        /// regex that matches everything, it is an unfinished line, and it gets kept.
        private static func text(_ node: Node?) -> String? {
            guard let node, !EspansoImporter.isEmpty(node), let text = node.string, !text.isEmpty
            else { return nil }
            return text
        }

        private static func strings(_ node: Node) -> [String] {
            if let sequence = node.sequence { return sequence.compactMap(\.string) }
            return node.string.map { [$0] } ?? []
        }

        /// British in the API, American on the wire.
        private static func uppercaseStyle(_ raw: String?) -> UppercaseStyle? {
            switch raw {
            case "capitalize": return .capitalise
            case "capitalize_words": return .capitaliseWords
            case "uppercase": return .uppercase
            default: return nil
            }
        }

        // MARK: Keeping and refusing

        private mutating func keep(_ key: String, _ node: Node, note: String) {
            keep(KeptFragment(key: key, fragment: YAMLFragment.text(from: node), note: note))
        }

        /// Keeps a key whose value is not the scalar the reader needed, and does nothing when it is.
        private mutating func keepUnreadable(_ key: String, _ node: Node) {
            if Self.text(node) == nil { keepValue(key, node) }
        }

        private mutating func keepValue(_ key: String, _ node: Node) {
            keep(key, node, note: "unsupported value for '\(key)'")
        }

        private mutating func keep(_ kept: KeptFragment) {
            snippet.unmapped[kept.key] = kept.fragment
            report.append("\(file) › \(match): kept \(kept.note)")
        }

        private func malformed(_ reason: String) -> EspansoImportError {
            .malformed(file: file, reason: reason)
        }
    }
}
