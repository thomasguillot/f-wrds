import Foundation
import Yams

// The variables inside one Espanso match, and the forms among them. Third of the three scales the
// importer reads at — file, match, variable — and the one whose vocabulary is largest.

extension EspansoImporter {

    /// Reads one `vars:` or `global_vars:` entry.
    enum VariableReader {

        /// An unknown *type* is kept whole — there is nothing to half-map — where an unknown
        /// *parameter* of a known type is kept beside a variable that otherwise works.
        static func parse(_ node: Node, index: Int, in file: String) throws -> ParsedVariable {
            guard let mapping = node.mapping else {
                throw EspansoImportError.malformed(file: file, reason: "a variable must be a mapping")
            }
            let name = mapping["name"]?.string ?? ""
            let type = mapping["type"]?.string ?? ""
            let params = mapping["params"]?.mapping
            // Unnamed variables cannot be referenced, but they still have to be kept apart from each
            // other in `unmapped`.
            let path = name.isEmpty ? "#\(index + 1)" : name
            var parsed = ParsedVariable()
            // Only what was actually *read* counts as consumed: a parameter of a shape this cannot
            // use falls through to `leftovers` and is kept verbatim rather than quietly defaulted.
            var consumed: Set<String> = []

            switch type {
            case "date":
                (parsed, consumed) = dateVariable(named: name, params: params)
            case "clipboard":
                parsed.variable = Variable(name: name, kind: .clipboard)
            case "choice", "random":
                (parsed, consumed) = choiceVariable(named: name, params: params, variable: path)
            case "echo":
                parsed.variable = Variable(name: name, kind: .echo(value: params?["echo"]?.string ?? ""))
                consumed = consuming("echo", of: params, as: \.string)
            case "shell":
                parsed.variable = Variable(
                    name: name,
                    kind: .shell(command: params?["cmd"]?.string ?? "",
                                 timeoutSeconds: EspansoImporter.shellTimeoutSeconds))
                consumed = consuming("cmd", of: params, as: \.string)
            case "form":
                (parsed, consumed) = formVariable(named: name, params: params, variable: path)
            default:
                parsed.kept.append(KeptFragment(key: "var:\(path)",
                                                fragment: YAMLFragment.text(from: node),
                                                note: "unsupported variable '\(name)' of type '\(type)'"))
                return parsed
            }
            parsed.kept += leftovers(of: mapping, params: params, consumed: consumed, variable: path)
            return parsed
        }

        /// Espanso lets a date variable leave out its format; the renderer cannot, so one is chosen
        /// and the choice is reported rather than made quietly.
        private static func dateVariable(named name: String, params: Node.Mapping?)
            -> (parsed: ParsedVariable, consumed: Set<String>) {
            let format = params?["format"]?.string
            let fallback = EspansoImporter.fallbackDateFormat
            let variable = Variable(name: name,
                                    kind: .date(format: format ?? fallback,
                                                offsetSeconds: params?["offset"]?.int ?? 0))
            let notes = format == nil
                ? ["no format on date variable '\(name)'; used '\(fallback)'"] : []
            let consumed = consuming("format", of: params, as: \.string)
                .union(consuming("offset", of: params, as: \.int))
            return (ParsedVariable(variable: variable, notes: notes), consumed)
        }

        /// `key`, if the parameter is there and `read` could make sense of it — and nothing if not,
        /// so a value of an unexpected shape falls through to `leftovers` and is kept verbatim
        /// instead of vanishing into a default. Consuming what was *read* rather than what might
        /// have been is the whole discipline: the list is not allowed to drift from the reading.
        private static func consuming<Value>(_ key: String, of params: Node.Mapping?,
                                             as read: (Node) -> Value?) -> Set<String> {
            params?[key].flatMap(read) == nil ? [] : [key]
        }

        /// `values` is what forms use and what the mapping table calls it; `choices` is what
        /// Espanso's random extension writes. Both mean the same list.
        private static func choiceVariable(named name: String, params: Node.Mapping?, variable: String)
            -> (parsed: ParsedVariable, consumed: Set<String>) {
            let key = params?["values"] != nil ? "values" : "choices"
            guard let picked = options(from: params?[key], path: key, variable: variable) else {
                // A list of a shape this cannot read is left unconsumed, so `leftovers` keeps it
                // verbatim: an empty picker an export can put right beats a silent deletion.
                return (ParsedVariable(variable: Variable(name: name, kind: .choice(options: []))), [])
            }
            let variable = Variable(name: name, kind: .choice(options: picked.options))
            return (ParsedVariable(variable: variable, kept: picked.kept), [key])
        }

        /// A `type: form` variable, plus the wording of its layout when there is any.
        ///
        /// The layout is inlined into the content, so its *placeholders* survive as `{{var.field}}`
        /// tokens — but the prose between them is the prompt Espanso shows in its own form panel,
        /// and nothing in our model has a home for it. It only reaches the content at all if the
        /// content referred to the form as a whole. Keeping the raw layout costs one fragment and
        /// lets an export put the panel back exactly as its author wrote it.
        private static func formVariable(named name: String, params: Node.Mapping?, variable: String)
            -> (parsed: ParsedVariable, consumed: Set<String>) {
            let layout = params?["layout"]?.string
            let form = formFields(layout: layout, spec: params?["fields"]?.mapping, variable: variable)
            var kept = form.kept
            if let node = params?["layout"], let layout, hasWording(layout) {
                kept.append(KeptFragment(key: "var:\(variable).layout",
                                         fragment: YAMLFragment.text(from: node),
                                         note: "the wording of the layout of form '\(name)'"))
            }
            let consumed = consuming("layout", of: params, as: \.string)
                .union(consuming("fields", of: params, as: \.mapping))
            let parsed = ParsedVariable(variable: Variable(name: name, kind: .form(fields: form.fields)),
                                        layout: layout, kept: kept)
            return (parsed, consumed)
        }

        /// Whether a layout says anything beyond naming its fields. `[[first]] [[last]]` says
        /// nothing a list of fields does not; "Dear [[first]]," does.
        private static func hasWording(_ layout: String) -> Bool {
            guard let placeholder else { return !layout.isEmpty }
            let stripped = placeholder.stringByReplacingMatches(
                in: layout, range: NSRange(layout.startIndex..., in: layout), withTemplate: "")
            return stripped.contains { !$0.isWhitespace }
        }

        /// Everything about a mapped variable that its type did not account for.
        private static func leftovers(of mapping: Node.Mapping, params: Node.Mapping?,
                                      consumed: Set<String>, variable: String) -> [KeptFragment] {
            var kept: [KeptFragment] = []
            let structural: Set<String> = ["name", "type", "params"]
            for (key, value) in mapping where !structural.contains(key.string ?? "") {
                kept.append(fragment(path: key.string ?? "", of: variable, node: value))
            }
            guard let params else { return kept }
            for (key, value) in params where !consumed.contains(key.string ?? "") {
                kept.append(fragment(path: key.string ?? "", of: variable, node: value))
            }
            return kept
        }

        private static func fragment(path: String, of variable: String, node: Node) -> KeptFragment {
            KeptFragment(key: "var:\(variable).\(path)", fragment: YAMLFragment.text(from: node),
                         note: "unsupported parameter '\(path)' of variable '\(variable)'")
        }

        /// A list of choices, or `nil` when the value is not one — which leaves it unconsumed, and
        /// so kept verbatim, rather than turned into a picker with nothing in it.
        ///
        /// Espanso spells the list two ways and both are read here: a YAML sequence, and a block
        /// scalar with one choice per line (`values: |`), which is the spelling its own form
        /// documentation uses. An entry may also be a `{label:, id:}` pair, where the label is what
        /// the user picks and the id is what something downstream wanted — F Wrds expands the label
        /// and keeps the id, so an export can put the pair back together.
        private static func options(from node: Node?, path: String,
                                    variable: String) -> (options: [String], kept: [KeptFragment])? {
            guard let node, !EspansoImporter.isEmpty(node) else { return nil }
            guard let list = node.sequence else {
                guard let block = node.string else { return nil }
                let lines = block.split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                return (lines.filter { !$0.isEmpty }, [])
            }
            var options: [String] = []
            var kept: [KeptFragment] = []
            for (index, value) in list.enumerated() {
                guard let mapping = value.mapping else {
                    options.append(value.string ?? "")
                    continue
                }
                options.append(mapping["label"]?.string ?? "")
                for (key, inner) in mapping where key.string != "label" {
                    kept.append(fragment(path: "\(path).\(index).\(key.string ?? "")",
                                         of: variable, node: inner))
                }
            }
            return (options, kept)
        }

        // MARK: Forms

        /// The fields of a form, in the order the layout asks for them — that is the order the user
        /// reads, where `fields:` is a mapping whose own order is an implementation detail. Fields
        /// the layout never mentions still come along, because their answers may be read by name.
        static func formFields(layout: String?, spec: Node.Mapping?,
                               variable: String) -> (fields: [FormField], kept: [KeptFragment]) {
            var names = layout.map(placeholders(in:)) ?? []
            if let spec {
                for name in spec.compactMap({ $0.key.string }) where !names.contains(name) {
                    names.append(name)
                }
            }
            var fields: [FormField] = []
            var kept: [KeptFragment] = []
            for name in names {
                let field = formField(named: name, spec: spec?[name], variable: variable)
                // Espanso has no per-field label, and the name is what its own panel shows.
                fields.append(FormField(name: name, label: name, kind: field.kind))
                kept += field.kept
            }
            return (fields, kept)
        }

        private static func formField(named name: String, spec: Node?, variable: String)
            -> (kind: FormField.Kind, kept: [KeptFragment]) {
            // A field named only by the layout is a plain text field, which is the common case.
            guard let spec else { return (.text(default: ""), []) }
            let path = "fields.\(name)"
            guard let mapping = spec.mapping else {
                return (.text(default: ""), [fragment(path: path, of: variable, node: spec)])
            }
            let type = mapping["type"]?.string
            var consumed: Set<String> = []
            var kept: [KeptFragment] = []
            let kind: FormField.Kind
            if type == "choice" || type == "list" {
                // One kind here, two spellings in Espanso. `choice` is the one an export can write
                // back unaided, so `list` stays in `unmapped` for it to restore.
                if type == "choice" { consumed.insert("type") }
                if let picked = options(from: mapping["values"], path: "\(path).values",
                                        variable: variable) {
                    kind = .choice(options: picked.options)
                    kept = picked.kept
                    consumed.insert("values")
                } else {
                    kind = .choice(options: [])
                }
            } else {
                // A type nobody recognises is not a text field, it is a field whose type was thrown
                // away — and `default` and `multiline` are read only by the kinds that carry them,
                // so a `default:` on a choice is kept rather than quietly ignored.
                if type == "text" { consumed.insert("type") }
                let multiline = mapping["multiline"]?.bool
                let text = mapping["default"]?.string
                if multiline != nil { consumed.insert("multiline") }
                if text != nil { consumed.insert("default") }
                kind = multiline == true ? .multiline(default: text ?? "") : .text(default: text ?? "")
            }
            for (key, value) in mapping where !consumed.contains(key.string ?? "") {
                kept.append(fragment(path: "\(path).\(key.string ?? "")", of: variable, node: value))
            }
            return (kind, kept)
        }

        /// `[[name]]`, tolerating spaces inside the brackets.
        private static let placeholder = try? NSRegularExpression(
            pattern: #"\[\[\s*([A-Za-z_][\w-]*)\s*\]\]"#)

        /// The field names a layout asks for, in order, without repeats.
        ///
        /// Shared with the exporter, which has to know which fields a layout it is about to write
        /// will name when this reads it back — a question only this can answer, since a name the
        /// pattern cannot spell is a name that will not be found.
        static func placeholders(in layout: String) -> [String] {
            guard let placeholder else { return [] }
            var names: [String] = []
            let range = NSRange(layout.startIndex..., in: layout)
            for match in placeholder.matches(in: layout, range: range) {
                guard let captured = Range(match.range(at: 1), in: layout) else { continue }
                let name = String(layout[captured])
                if !names.contains(name) { names.append(name) }
            }
            return names
        }

        /// `[[field]]` → `{{variable.field}}`: Espanso's layout placeholders, spelled the way the
        /// renderer reads form answers.
        static func inliningFields(of layout: String, into variable: String) -> String {
            guard let placeholder else { return layout }
            return placeholder.stringByReplacingMatches(
                in: layout, range: NSRange(layout.startIndex..., in: layout),
                withTemplate: "{{\(NSRegularExpression.escapedTemplate(for: variable)).$1}}")
        }

        /// Puts `layout` where the content said `{{variable}}`. A form variable is several values,
        /// so the token that stood for the whole of it has to become the layout that lays them out.
        static func inlining(_ layout: String, of variable: String, into content: String) -> String {
            let pattern = #"\{\{\s*"# + NSRegularExpression.escapedPattern(for: variable) + #"\s*\}\}"#
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return content }
            return expression.stringByReplacingMatches(
                in: content, range: NSRange(content.startIndex..., in: content),
                withTemplate: NSRegularExpression.escapedTemplate(for: layout))
        }
    }
}
