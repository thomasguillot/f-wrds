import Foundation
import Yams

// The variables inside one Espanso match, and the forms among them — the writing side of
// `EspansoVariableReader`, and split from the match writer at the same seam: a variable is its own
// scale, and the vocabulary at that scale is the largest part of the border.

extension EspansoExporter {

    /// Writes one variable as one `vars:` or `global_vars:` entry.
    enum VariableWriter {

        /// A kind as Espanso writes it.
        private struct Written {
            let type: String
            var params: [(String, YAMLNode)] = []
            /// The parameters whose *nested* fragments these params have already put back. Anything
            /// nested under another name has nowhere better to go than `Graft.applied(to:consuming:)`.
            var claimed: Set<String> = []
        }

        /// One entry, or nothing at all for a reference to a global.
        ///
        /// Espanso has no variable type for such a reference: a `{{company}}` in the content reads
        /// the file's own `global_vars` block directly, so the block is the whole of what has to be
        /// written and a `vars:` entry beside it would only shadow it.
        static func node(for variable: Variable, graft: Graft) -> YAMLNode? {
            guard let written = shape(of: variable.kind, graft: graft) else { return nil }
            var entries: [(String, YAMLNode)] = [("name", .string(variable.name)),
                                                 ("type", .plain(written.type))]
            // Everything kept beside a variable goes under `params`, which is where all but a
            // vanishing few of them came from — and where an unread one re-imports under the key it
            // had, which is what the round trip is measured on.
            let params = graft.applied(to: written.params, consuming: written.claimed)
            if !params.isEmpty { entries.append(("params", .mapping(params))) }
            return .mapping(entries)
        }

        /// The type name a kind is written under, and its parameters in Espanso's own order.
        private static func shape(of kind: Variable.Kind, graft: Graft) -> Written? {
            switch kind {
            case .date(let format, let offsetSeconds):
                var params: [(String, YAMLNode)] = [("format", .string(format))]
                // Espanso's own default, so writing it back would only be noise.
                if offsetSeconds != 0 { params.append(("offset", .plain("\(offsetSeconds)"))) }
                return Written(type: "date", params: params)
            case .clipboard:
                return Written(type: "clipboard")
            case .choice(let options):
                let key = choicesKey(graft: graft)
                return Written(type: "choice",
                               params: [(key, values(options, graft: graft.nested[key]))],
                               claimed: [key])
            case .echo(let value):
                return Written(type: "echo", params: [("echo", .string(value))])
            case .shell(let command, _):
                // The timeout is not Espanso's — it is the budget the import invented so that a hung
                // command is a warning rather than a frozen app. There is no key to write it under.
                return Written(type: "shell", params: [("cmd", .string(command))])
            case .form(let fields):
                return form(fields, graft: graft)
            case .global:
                return nil
            }
        }

        // MARK: Choices

        /// `values`, or the other name Espanso has for the same list.
        ///
        /// The `random` extension spells it `choices`, and the import read it under whichever name it
        /// found and kept its leftovers under that one. A fragment kept as `choices.0.id` only comes
        /// back under that key if the list goes back out under that name, so the fragments decide the
        /// spelling and `values` is what is written when they say nothing either way.
        private static func choicesKey(graft: Graft) -> String {
            let named: (String) -> Bool = { graft.direct[$0] != nil || graft.nested[$0] != nil }
            return !named("values") && named("choices") ? "choices" : "values"
        }

        /// A choice's options, with any `{label:, id:}` pairs put back together.
        ///
        /// Only the label was ever ours; the rest of such a pair was kept aside, and an option that
        /// has something kept against its index goes back out as the pair it arrived as.
        private static func values(_ options: [String], graft: Graft?) -> YAMLNode {
            .sequence(options.enumerated().map { index, option in
                guard let pair = graft?.nested["\(index)"], !pair.direct.isEmpty else {
                    return .string(option)
                }
                return .mapping(pair.applied(to: [("label", .string(option))]))
            })
        }

        // MARK: Forms

        private static func form(_ fields: [FormField], graft: Graft) -> Written {
            let layout = writtenLayout(of: fields, graft: graft)
            var params: [(String, YAMLNode)] = [("layout", .string(layout ?? self.layout(of: fields)))]
            if let spec = self.fields(fields, namedIn: layout,
                                      graft: graft.nested["fields"] ?? Graft()) {
                params.append(("fields", spec))
            }
            return Written(type: "form", params: params, claimed: ["fields"])
        }

        /// A form's `fields:` mapping, or nothing when no field says more than its name already does.
        ///
        /// A plain text field the layout already names is exactly what Espanso makes of a name in a
        /// layout, so writing a spec for one would say nothing. Everything else earns its entry — and
        /// a field the layout does *not* name earns one whatever its kind, because the layout and
        /// this mapping are the only two places a re-import looks for the fields, and a field named
        /// in neither is a field deleted while the content goes on asking for it.
        static func fields(_ fields: [FormField], namedIn layout: String?, graft: Graft) -> YAMLNode? {
            // The layout is read here exactly as the import will read it back, rather than by a
            // second rule that could drift from it: a name it cannot spell (`[[full name]]`) is a
            // name it will not find either.
            let named = Set(EspansoImporter.VariableReader.placeholders(in: layout ?? ""))
            let generated = fields.compactMap { field -> (String, YAMLNode)? in
                let own = graft.nested[field.name] ?? Graft()
                var spec = own.applied(to: self.spec(of: field.kind, graft: own),
                                       consuming: consumedKeys(of: field.kind))
                if spec.isEmpty && !named.contains(field.name) { spec = [("type", .plain("text"))] }
                return spec.isEmpty ? nil : (field.name, .mapping(spec))
            }
            let entries = graft.applied(to: generated, consuming: Set(fields.map(\.name)))
            return entries.isEmpty ? nil : .mapping(entries)
        }

        /// The keys whose *nested* fragments `spec(of:graft:)` has already written back itself, and
        /// which `Graft.applied(to:consuming:)` must therefore not write a second time under their
        /// dotted names — the field-level counterpart of `Written.claimed`.
        ///
        /// Only a choice has any: its `values` sequence is rebuilt from the options with each
        /// option's kept fragments grafted back onto it, so a `values.0.id` re-emitted alongside
        /// would be the same fragment written twice, once in the sequence where it belongs and once
        /// as a junk sibling key that means nothing to Espanso and re-imports as noise.
        private static func consumedKeys(of kind: FormField.Kind) -> Set<String> {
            if case .choice = kind { return ["values"] }
            return []
        }

        private static func spec(of kind: FormField.Kind, graft: Graft) -> [(String, YAMLNode)] {
            switch kind {
            case .text(let value):
                return value.isEmpty ? [] : [("default", .string(value))]
            case .multiline(let value):
                var spec: [(String, YAMLNode)] = [("multiline", .plain("true"))]
                if !value.isEmpty { spec.append(("default", .string(value))) }
                return spec
            case .choice(let options):
                return [("type", .plain("choice")),
                        ("values", values(options, graft: graft.nested["values"]))]
            }
        }

        /// The layout that will actually be written, as text.
        ///
        /// A kept layout overrides the reconstruction — it is the wording its author wrote — so it is
        /// the one whose field names count. `nil` when there is a kept layout that is not a string at
        /// all, which names nothing and leaves every field to be spelled out under `fields:`.
        private static func writtenLayout(of fields: [FormField], graft: Graft) -> String? {
            guard let kept = graft.direct["layout"] else { return layout(of: fields) }
            return (try? Yams.compose(yaml: kept))?.string
        }

        /// A layout that names a form's fields in order.
        ///
        /// Espanso needs a layout to know what to ask for, and this one asks for exactly the fields
        /// and nothing else — the wording that stood between them on the way in, if there was any,
        /// was kept as a fragment and comes back over the top of this. The content is unaffected
        /// either way: it reads the answers back by name, which is a spelling Espanso reads too.
        static func layout(of fields: [FormField]) -> String {
            fields.map { "[[\($0.name)]]" }.joined(separator: " ")
        }

        /// The layout `content` would be, if the content were nothing but this form laid out — and
        /// `nil` when it is anything else.
        ///
        /// This is the question the match-level `form:` shorthand turns on, and it is answered by
        /// doing the import's own inlining and checking it lands back on the content it started
        /// from. That catches everything a hand-written rule would miss: a `[[literal]]` already in
        /// the content, a token for a field that is not there, a field the content never names. The
        /// fields are then read back out of the layout the same way a re-import will read them,
        /// because a layout that names them in another order is another form.
        static func layout(of fields: [FormField], in content: String, named name: String) -> String? {
            var layout = content
            for field in fields {
                layout = layout.replacingOccurrences(of: "{{\(name).\(field.name)}}",
                                                     with: "[[\(field.name)]]")
            }
            guard EspansoImporter.VariableReader.inliningFields(of: layout, into: name) == content,
                  EspansoImporter.VariableReader.placeholders(in: layout) == fields.map(\.name)
            else { return nil }
            return layout
        }
    }
}
