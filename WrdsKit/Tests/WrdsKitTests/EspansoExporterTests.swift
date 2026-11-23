import Foundation
import Testing
import WrdsKit

// MARK: Fixtures and scratch files

/// One of the two committed Espanso fixtures, copied into the test bundle verbatim.
private func fixture(_ stem: String) throws -> URL {
    try #require(Bundle.module.url(forResource: stem, withExtension: "yml", subdirectory: "Fixtures"),
                 "fixture \(stem).yml is missing from the test bundle")
}

/// Runs `body` against a freshly created, empty directory that is removed afterwards.
private func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("EspansoExporterTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try body(directory)
}

/// Writes `contents` to `name` inside `directory` and hands back the URL.
@discardableResult
private func write(_ contents: String, to name: String, in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent(name, isDirectory: false)
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url
}

// MARK: The round trip

/// Exports every group and reads the result straight back, the way a user would: one file per
/// group, named after it, so even the report lines line up with the first import's.
///
/// Globals are Espanso's file-level block and this library's library-wide list, so they go out with
/// the first file only — writing them into every file would import them back N times.
private func roundTrip(_ result: EspansoImportResult) throws -> EspansoImportResult {
    try withTemporaryDirectory { directory in
        var urls: [URL] = []
        for (index, group) in result.groups.enumerated() {
            let text = EspansoExporter.export(group: group,
                                              globals: index == 0 ? result.globals : [])
            urls.append(try write(text, to: "\(group.name).yml", in: directory))
        }
        return try EspansoImporter.importFiles(urls)
    }
}

/// The same round trip, starting from YAML: some shapes are far easier to say in the file Espanso
/// would have written than in the model it becomes.
private func roundTrip(_ source: String, named name: String) throws
    -> (first: EspansoImportResult, second: EspansoImportResult) {
    try withTemporaryDirectory { directory in
        let first = try EspansoImporter.importFiles([try write(source, to: "\(name).yml",
                                                               in: directory)])
        return (first, try roundTrip(first))
    }
}

// MARK: Comparing models without their identities

/// A form field minus its identity.
private struct FieldShape: Equatable {
    let name: String
    let label: String
    let kind: FormField.Kind

    init(_ field: FormField) {
        name = field.name
        label = field.label
        kind = field.kind
    }
}

/// A variable minus its identity, and minus the identities inside a form's fields.
private struct VariableShape: Equatable {
    let name: String
    let fields: [FieldShape]?
    let kind: Variable.Kind?

    init(_ variable: Variable) {
        name = variable.name
        if case .form(let fields) = variable.kind {
            self.fields = fields.map(FieldShape.init)
            kind = nil
        } else {
            self.fields = nil
            kind = variable.kind
        }
    }
}

private struct SnippetShape: Equatable {
    let triggers: [String]
    let regexTrigger: String?
    let label: String
    let content: String
    let wordBoundary: Bool
    let propagateCase: Bool
    let uppercaseStyle: UppercaseStyle?
    let variables: [VariableShape]
    let isEnabled: Bool
    let unmapped: [String: String]

    init(_ snippet: Snippet) {
        triggers = snippet.triggers
        regexTrigger = snippet.regexTrigger
        label = snippet.label
        content = snippet.content
        wordBoundary = snippet.wordBoundary
        propagateCase = snippet.propagateCase
        uppercaseStyle = snippet.uppercaseStyle
        variables = snippet.variables.map(VariableShape.init)
        isEnabled = snippet.isEnabled
        unmapped = snippet.unmapped
    }
}

private struct GroupShape: Equatable {
    let name: String
    let snippets: [SnippetShape]

    init(_ group: SnippetGroup) {
        name = group.name
        snippets = group.snippets.map(SnippetShape.init)
    }
}

private func shape(_ result: EspansoImportResult) -> (groups: [GroupShape], globals: [VariableShape]) {
    (result.groups.map(GroupShape.init), result.globals.map { VariableShape($0.variable) })
}

// MARK: Reaching into an export

/// One group's export, for tests that read the YAML rather than re-import it.
private func exported(_ snippets: [Snippet], globals: [GlobalVariable] = []) -> String {
    EspansoExporter.export(group: SnippetGroup(name: "test", snippets: snippets), globals: globals)
}

private func group(named name: String, in result: EspansoImportResult) throws -> SnippetGroup {
    try #require(result.groups.first { $0.name == name }, "no group named \(name)")
}

private func snippet(_ trigger: String, in group: SnippetGroup) throws -> Snippet {
    try #require(group.snippets.first { $0.triggers.contains(trigger) },
                 "no snippet triggered by \(trigger) in \(group.name)")
}

private func variable(_ name: String, in snippet: Snippet) throws -> Variable {
    try #require(snippet.variables.first { $0.name == name },
                 "no variable named \(name) in the snippet")
}

@Suite("EspansoExporter")
struct EspansoExporterTests {

    // MARK: The round trip — the whole point of the exporter

    @Test("base.yml survives an export and a re-import unchanged")
    func roundTripsTheMappedSurface() throws {
        let first = try EspansoImporter.importFiles([fixture("base")])
        let second = try roundTrip(first)
        #expect(shape(second).groups == shape(first).groups)
        #expect(shape(second).globals == shape(first).globals)
        // base.yml is the file that maps completely, so the export of it must map completely too.
        #expect(second.unmappedReport.isEmpty, "\(second.unmappedReport)")
    }

    @Test("exotic.yml survives an export and a re-import unchanged, unmapped keys and all")
    func roundTripsWhatCouldNotBeMapped() throws {
        let first = try EspansoImporter.importFiles([fixture("exotic")])
        let second = try roundTrip(first)
        #expect(shape(second).groups == shape(first).groups)
        // Every fragment kept on the way in is kept again on the way back in, byte for byte —
        // asserted per snippet as well as in bulk, so a failure names the match it came from.
        for (before, after) in zip(try group(named: "exotic", in: first).snippets,
                                   try group(named: "exotic", in: second).snippets) {
            #expect(before.unmapped == after.unmapped, "\(before.triggers)\(before.regexTrigger ?? "")")
        }
        // The same things are reported, though not in the same order: kept keys are re-emitted in
        // one sorted block rather than where their author wrote them.
        #expect(Set(second.unmappedReport) == Set(first.unmappedReport))
        #expect(second.unmappedReport.count == first.unmappedReport.count)
        #expect(!first.unmappedReport.isEmpty)
    }

    @Test("Both fixtures exported into one directory still round-trip together")
    func roundTripsBothFixturesTogether() throws {
        let first = try EspansoImporter.importFiles([fixture("base"), fixture("exotic")])
        let second = try roundTrip(first)
        #expect(shape(second).groups == shape(first).groups)
        #expect(shape(second).globals == shape(first).globals)
        #expect(Set(second.unmappedReport) == Set(first.unmappedReport))
    }

    @Test("Exporting the same group twice gives the same bytes")
    func exportsDeterministically() throws {
        let exotic = try group(named: "exotic", in: EspansoImporter.importFiles([fixture("exotic")]))
        let first = EspansoExporter.export(group: exotic, globals: [])
        for _ in 0..<8 {
            #expect(EspansoExporter.export(group: exotic, globals: []) == first)
        }
    }

    // MARK: The wire vocabulary

    @Test("`uppercase_style` is spelled the American way Espanso reads")
    func writesUppercaseStyleOnTheWire() {
        let styles: [UppercaseStyle: String] = [.capitalise: "capitalize",
                                                .capitaliseWords: "capitalize_words",
                                                .uppercase: "uppercase"]
        for (style, wire) in styles {
            let text = exported([Snippet(triggers: [":x"], content: "y", uppercaseStyle: style)])
            #expect(text.contains("uppercase_style: \(wire)"), "\(text)")
        }
        #expect(exported([Snippet(triggers: [":x"], content: "y", uppercaseStyle: .capitaliseWords)])
            .contains("uppercase_style: capitalize_words"))
    }

    @Test("A single trigger is `trigger`, several are `triggers`")
    func writesTriggersBySpelling() {
        #expect(exported([Snippet(triggers: [":x"], content: "y")]).contains("- trigger: \":x\""))
        let many = exported([Snippet(triggers: [":x", ":z"], content: "y")])
        #expect(many.contains("- triggers:\n      - \":x\"\n      - \":z\""), "\(many)")
    }

    @Test("A regex trigger is `regex`, and no `trigger` is invented for it")
    func writesRegexTriggers() {
        let text = exported([Snippet(regexTrigger: ":a(?P<n>.*)", content: "y")])
        #expect(text.contains("regex: \":a(?P<n>.*)\""))
        #expect(!text.contains("trigger:"))
    }

    @Test("Flags and labels are written only when they say something")
    func omitsDefaults() {
        let bare = exported([Snippet(triggers: [":x"], content: "y")])
        #expect(!bare.contains("word:"))
        #expect(!bare.contains("propagate_case:"))
        #expect(!bare.contains("uppercase_style:"))
        #expect(!bare.contains("label:"))
        #expect(!bare.contains("vars:"))
        let full = exported([Snippet(triggers: [":x"], label: "L", content: "y",
                                     wordBoundary: true, propagateCase: true)])
        #expect(full.contains("word: true"))
        #expect(full.contains("propagate_case: true"))
        #expect(full.contains("label: \"L\""))
        // Espanso records no such thing as a switched-off match, and leaving one out of the export
        // would delete it from the user's config rather than disable it.
        #expect(exported([Snippet(triggers: [":x"], content: "y", isEnabled: false)])
            .contains("trigger: \":x\""))
    }

    @Test("An empty group is an empty match list, not a file with nothing in it")
    func writesAnEmptyMatchList() throws {
        let text = EspansoExporter.export(group: SnippetGroup(name: "empty"), globals: [])
        #expect(text == "matches: []\n")
        try withTemporaryDirectory { directory in
            let url = try write(text, to: "empty.yml", in: directory)
            let result = try EspansoImporter.importFiles([url])
            #expect(try group(named: "empty", in: result).snippets.isEmpty)
            #expect(result.unmappedReport.isEmpty)
        }
    }

    @Test("The key order is the one Espanso's own files are written in")
    func writesKeysInAFixedOrder() {
        let snippet = Snippet(triggers: [":x"], label: "L", content: "body", wordBoundary: true,
                              propagateCase: true, uppercaseStyle: .capitalise,
                              variables: [Variable(name: "d",
                                                   kind: .date(format: "%H", offsetSeconds: 60))],
                              unmapped: ["zebra": "1", "alpha": "2"])
        #expect(exported([snippet]) == """
            matches:
              - trigger: ":x"
                label: "L"
                replace: "body"
                word: true
                propagate_case: true
                uppercase_style: capitalize
                vars:
                  - name: "d"
                    type: date
                    params:
                      format: "%H"
                      offset: 60
                alpha: 2
                zebra: 1

            """)
    }

    // MARK: Variables

    @Test("Every variable kind Espanso knows is written back in its own spelling")
    func writesTheVariableVocabulary() {
        let snippet = Snippet(
            triggers: [":x"], content: "y",
            variables: [Variable(name: "d", kind: .date(format: "%H", offsetSeconds: 0)),
                        Variable(name: "c", kind: .clipboard),
                        Variable(name: "p", kind: .choice(options: ["a", "b"])),
                        Variable(name: "e", kind: .echo(value: "hi")),
                        Variable(name: "s", kind: .shell(command: "ls", timeoutSeconds: 10))])
        let text = exported([snippet])
        #expect(text.contains(#"- name: "d"\#n        type: date\#n        params:\#n"#
            + #"          format: "%H""#))
        // Espanso has no timeout of its own, and a zero offset is its default: neither is written.
        #expect(!text.contains("offset:"))
        #expect(!text.contains("timeout"))
        #expect(text.contains("- name: \"c\"\n        type: clipboard\n"))
        #expect(!text.contains("params: {}"))
        #expect(text.contains("type: choice\n        params:\n          values:\n            - \"a\""))
        #expect(text.contains("type: echo\n        params:\n          echo: \"hi\""))
        #expect(text.contains("type: shell\n        params:\n          cmd: \"ls\""))
    }

    @Test("A date offset is written when it is not the default")
    func writesNonZeroDateOffsets() {
        let text = exported([Snippet(triggers: [":x"], content: "y",
                                     variables: [Variable(name: "d",
                                                          kind: .date(format: "%H",
                                                                      offsetSeconds: -86_400))])])
        #expect(text.contains("offset: -86400"))
    }

    @Test("A global reference is not a variable Espanso has: the global_vars block covers it")
    func writesNothingForGlobalReferences() {
        let text = exported([Snippet(triggers: [":x"], content: "{{company}}",
                                     variables: [Variable(name: "company",
                                                          kind: .global(name: "company"))])])
        #expect(!text.contains("vars:"))
        #expect(text.contains("replace: \"{{company}}\""))
    }

    @Test("Globals are the file-level block, and survive a round trip")
    func writesGlobalVariables() throws {
        let globals = [GlobalVariable(variable: Variable(name: "company", kind: .echo(value: "F Wrds"))),
                       GlobalVariable(variable: Variable(name: "today",
                                                         kind: .date(format: "%Y", offsetSeconds: 0)))]
        let text = exported([Snippet(triggers: [":x"], content: "{{company}}")], globals: globals)
        #expect(text.contains("global_vars:\n  - name: \"company\"\n    type: echo"))
        try withTemporaryDirectory { directory in
            let url = try write(text, to: "g.yml", in: directory)
            let result = try EspansoImporter.importFiles([url])
            #expect(result.globals.map { VariableShape($0.variable) }
                == globals.map { VariableShape($0.variable) })
        }
    }

    // MARK: Forms

    @Test("A form named `form` whose content is its layout goes back out as the shorthand")
    func writesTheFormShorthand() throws {
        let base = try group(named: "base", in: EspansoImporter.importFiles([fixture("base")]))
        let text = EspansoExporter.export(group: base, globals: [])
        #expect(text.contains(#"form: "Hi [[name]],\n\n[[body]]\n\n[[urgency]]""#), "\(text)")
        #expect(text.contains("form_fields:\n      body:\n        multiline: true"), "\(text)")
        #expect(text.contains("urgency:\n        type: choice\n        values:\n          - \"Whenever\""),
                "\(text)")
    }

    @Test("A form variable gets a layout reconstructed from its fields, in their order")
    func reconstructsAFormLayout() {
        let fields = [FormField(name: "ticket", label: "ticket", kind: .text(default: "")),
                      FormField(name: "owner", label: "owner", kind: .text(default: "Thomas"))]
        let text = exported([Snippet(triggers: [":x"], content: "{{d.ticket}} {{d.owner}}",
                                     variables: [Variable(name: "d", kind: .form(fields: fields))])])
        #expect(text.contains("type: form\n        params:\n          layout: \"[[ticket]] [[owner]]\""),
                "\(text)")
        // A field the layout already names and that carries nothing else needs no spec at all.
        #expect(text.contains("fields:\n            owner:\n              default: \"Thomas\""), "\(text)")
        #expect(!text.contains("ticket:"))
    }

    @Test("The shorthand is only for a form named `form` that is the whole of its match")
    func keepsFormsTheShorthandCannotExpress() {
        let fields = [FormField(name: "name", label: "name", kind: .text(default: ""))]
        // Prose around the fields is no obstacle — that is what the shorthand's layout is for —
        // but another name, or another variable beside it, is.
        let named = exported([Snippet(triggers: [":x"], content: "Dear {{d.name}}, regards",
                                      variables: [Variable(name: "d", kind: .form(fields: fields))])])
        #expect(named.contains("replace: \"Dear {{d.name}}, regards\""), "\(named)")
        #expect(named.contains("type: form"), "\(named)")
        #expect(!named.contains("form_fields:"), "\(named)")

        let crowded = exported([Snippet(
            triggers: [":x"], content: "Dear {{form.name}} — {{clip}}",
            variables: [Variable(name: "form", kind: .form(fields: fields)),
                        Variable(name: "clip", kind: .clipboard)])])
        #expect(crowded.contains("replace:"), "\(crowded)")
        #expect(!crowded.contains("form_fields:"), "\(crowded)")

        // A field the content never names cannot survive as a layout placeholder either.
        let partial = exported([Snippet(
            triggers: [":x"], content: "{{form.name}}",
            variables: [Variable(name: "form",
                                 kind: .form(fields: fields + [FormField(name: "z", label: "z",
                                                                         kind: .text(default: ""))]))])])
        #expect(!partial.contains("form_fields:"), "\(partial)")
    }

    @Test("A form with something kept against it stays the one spelling that can carry it")
    func keepsFormsWithFragmentsOfTheirOwn() throws {
        // A `type: form` named `form`, laid out in prose, whose content is nothing but the form:
        // everything the shorthand asks for — except that the shorthand has nowhere to put the
        // wording that was kept aside, and taking it would lose the fragment on the way out.
        let source = """
            matches:
              - trigger: ":x"
                replace: "{{form}}"
                vars:
                  - name: form
                    type: form
                    params:
                      layout: "Dear [[who]],"
            """
        try withTemporaryDirectory { directory in
            let first = try EspansoImporter.importFiles([try write(source, to: "prose.yml",
                                                                   in: directory)])
            let read = try snippet(":x", in: group(named: "prose", in: first))
            #expect(read.unmapped["var:form.layout"] == "\"Dear [[who]],\"")
            let text = EspansoExporter.export(group: try group(named: "prose", in: first), globals: [])
            #expect(!text.contains("form: \""), "\(text)")
            let url = try write(text, to: "prose.yml", in: directory)
            #expect(shape(try EspansoImporter.importFiles([url])).groups == shape(first).groups)
        }
    }

    @Test("A form field spelled as anything but a mapping comes back as what it was")
    func roundTripsFieldSpecsThatAreNotMappings() throws {
        let (first, second) = try roundTrip("""
            matches:
              - trigger: ":x"
                replace: "{{f}}"
                vars:
                  - name: f
                    type: form
                    params:
                      layout: "[[a]]"
                      fields:
                        a: "just a string"
            """, named: "spec")
        #expect(try snippet(":x", in: group(named: "spec", in: first))
            .unmapped["var:f.fields.a"] == "\"just a string\"")
        #expect(shape(second).groups == shape(first).groups)
        #expect(Set(second.unmappedReport) == Set(first.unmappedReport))
    }

    @Test("A list of choices kept under Espanso's other name for it goes back under that name")
    func roundTripsChoicesUnderTheirOwnSpelling() throws {
        let (first, second) = try roundTrip("""
            matches:
              - trigger: ":x"
                replace: "{{pick}}"
                vars:
                  - name: pick
                    type: random
                    params:
                      choices:
                        - label: "Yes please"
                          id: "affirmative"
                        - "No thanks"
            """, named: "picks")
        #expect(try snippet(":x", in: group(named: "picks", in: first))
            .unmapped["var:pick.choices.0.id"] == "\"affirmative\"")
        #expect(shape(second).groups == shape(first).groups)
        #expect(Set(second.unmappedReport) == Set(first.unmappedReport))
    }

    @Test("A field the written layout cannot name is spelled out under `fields:` instead")
    func namesEveryFieldTheLayoutDoesNot() throws {
        // The layout was kept for its wording, so it is the one written — and it names only `who`.
        // A field it does not name has to be named under `fields:`, or a re-import cannot know it
        // was ever there, while the content goes on asking for it.
        let (first, second) = try roundTrip("""
            matches:
              - trigger: ":x"
                replace: "{{f}}"
                vars:
                  - name: f
                    type: form
                    params:
                      layout: "Dear [[who]],"
                      fields:
                        extra:
                          type: text
                        full name: {}
            """, named: "layouts")
        let before = try snippet(":x", in: group(named: "layouts", in: first))
        #expect(before.unmapped["var:f.layout"] == "\"Dear [[who]],\"")
        guard case .form(let fields) = try variable("f", in: before).kind else {
            Issue.record("expected a form variable")
            return
        }
        #expect(fields.map(\.name) == ["who", "extra", "full name"])
        #expect(shape(second).groups == shape(first).groups)
        #expect(Set(second.unmappedReport) == Set(first.unmappedReport))
    }

    @Test("A variable kept whole goes back where it stood, not on the end")
    func keepsWholeVariablesInPlace() throws {
        // An unnamed one is kept under `var:#<n>`, where the number *is* where it stood: put it back
        // anywhere else and the key it comes back under is a different key.
        let (first, second) = try roundTrip("""
            matches:
              - trigger: ":x"
                replace: "{{a}}"
                vars:
                  - type: script
                    params:
                      args:
                        - fetch.py
                  - name: a
                    type: echo
                    params:
                      echo: "hi"
            """, named: "order")
        #expect(try snippet(":x", in: group(named: "order", in: first)).unmapped["var:#1"] != nil)
        #expect(shape(second).groups == shape(first).groups)
        #expect(Set(second.unmappedReport) == Set(first.unmappedReport))
    }

    @Test("A fragment that no longer parses costs one odd value, not an unreadable file")
    func writesUnparseableFragmentsAsText() throws {
        let text = exported([Snippet(triggers: [":x"], content: "y", unmapped: ["odd": "[unclosed"])])
        try withTemporaryDirectory { directory in
            let url = try write(text, to: "odd.yml", in: directory)
            let read = try snippet(":x", in: group(named: "odd",
                                                   in: EspansoImporter.importFiles([url])))
            #expect(read.unmapped["odd"] == "\"[unclosed\"")
        }
    }

    @Test("Multiline and choice fields keep their kinds through a round trip")
    func roundTripsFormFieldKinds() throws {
        let fields = [FormField(name: "a", label: "a", kind: .text(default: "x")),
                      FormField(name: "b", label: "b", kind: .multiline(default: "")),
                      FormField(name: "c", label: "c", kind: .choice(options: ["one", "two"]))]
        let built = Snippet(triggers: [":x"], content: "{{f.a}} {{f.b}} {{f.c}}",
                            variables: [Variable(name: "f", kind: .form(fields: fields))])
        try withTemporaryDirectory { directory in
            let url = try write(exported([built]), to: "forms.yml", in: directory)
            let read = try snippet(":x", in: group(named: "forms",
                                                   in: EspansoImporter.importFiles([url])))
            #expect(SnippetShape(read).variables == [VariableShape(built.variables[0])])
            #expect(read.content == built.content)
            #expect(read.unmapped.isEmpty)
        }
    }

    // MARK: Fragments going back where they came from

    @Test("A kept fragment is grafted back under its own key, as YAML rather than as text")
    func graftsFragmentsBackAsYAML() throws {
        let built = Snippet(triggers: [":x"], content: "y",
                            unmapped: ["search_terms": "- greeting\n- hello",
                                       "left_word": "true",
                                       "image_path": "\"$CONFIG/logo.png\""])
        let text = exported([built])
        #expect(text.contains("    image_path: \"$CONFIG/logo.png\""), "\(text)")
        #expect(text.contains("    left_word: true"), "\(text)")
        #expect(text.contains("    search_terms:\n      - greeting\n      - hello"), "\(text)")
        try withTemporaryDirectory { directory in
            let url = try write(text, to: "kept.yml", in: directory)
            let read = try snippet(":x", in: group(named: "kept",
                                                   in: EspansoImporter.importFiles([url])))
            #expect(read.unmapped == built.unmapped)
        }
    }

    @Test("A key that was written with nothing under it goes back out with nothing under it")
    func graftsNullFragments() throws {
        let text = exported([Snippet(triggers: [":x"], content: "y", unmapped: ["regex": ""])])
        #expect(text.contains("\n    regex:\n"), "\(text)")
        try withTemporaryDirectory { directory in
            let url = try write(text, to: "null.yml", in: directory)
            let read = try snippet(":x", in: group(named: "null",
                                                   in: EspansoImporter.importFiles([url])))
            #expect(read.unmapped == ["regex": ""])
            #expect(read.regexTrigger == nil)
        }
    }

    @Test("A whole variable Espanso understands and F Wrds does not is written back whole")
    func graftsWholeVariables() throws {
        let fragment = "name: ip\ntype: script\nparams:\n  args:\n  - python3\n  - fetch_ip.py"
        let text = exported([Snippet(triggers: [":x"], content: "{{ip}}",
                                     unmapped: ["var:ip": fragment])])
        #expect(text.contains("    vars:\n      - name: ip\n        type: script"), "\(text)")
        try withTemporaryDirectory { directory in
            let url = try write(text, to: "whole.yml", in: directory)
            let read = try snippet(":x", in: group(named: "whole",
                                                   in: EspansoImporter.importFiles([url])))
            #expect(read.unmapped["var:ip"] == fragment)
            #expect(read.variables.isEmpty)
        }
    }

    @Test("A parameter that could not be represented is grafted beside the ones that could")
    func graftsVariableParameters() {
        let snippet = Snippet(triggers: [":x"], content: "{{stamp}}",
                              variables: [Variable(name: "stamp",
                                                   kind: .date(format: "%H", offsetSeconds: 0))],
                              unmapped: ["var:stamp.locale": "\"fr-FR\""])
        #expect(exported([snippet]).contains("""
                    params:
                      format: "%H"
                      locale: "fr-FR"
            """), "\(exported([snippet]))")
    }

    @Test("A kept value the model could not read wins over the empty one it was given instead")
    func graftedParametersBeatTheirPlaceholders() {
        let snippet = Snippet(triggers: [":x"], content: "{{one}}",
                              variables: [Variable(name: "one", kind: .choice(options: []))],
                              unmapped: ["var:one.values": "from: a file"])
        let text = exported([snippet])
        #expect(text.contains("values:\n            from: a file"), "\(text)")
        #expect(!text.contains("values: []"), "\(text)")
    }

    @Test("Choice values written as label/id objects are put back together")
    func graftsChoiceValueObjects() {
        let snippet = Snippet(triggers: [":x"], content: "{{pick}}",
                              variables: [Variable(name: "pick",
                                                   kind: .choice(options: ["Yes please", "No thanks"]))],
                              unmapped: ["var:pick.values.0.id": "\"affirmative\""])
        #expect(exported([snippet]).contains("""
                      values:
                        - label: "Yes please"
                          id: "affirmative"
                        - "No thanks"
            """), "\(exported([snippet]))")
    }

    @Test("A form field's choice values are grafted into the sequence, not written twice")
    func graftsFormFieldChoiceValueObjects() {
        // The same round trip as the variable-level choice above, one scale in. The kept fragment
        // belongs *inside* the rebuilt `values` sequence, and re-emitting it beside that sequence
        // under its dotted name would write it twice — once where it means something, once as a
        // `values.0.id:` sibling Espanso has no use for and a re-import reads back as noise.
        let field = FormField(name: "pick", label: "Pick", kind: .choice(options: ["Yes please", "No"]))
        let snippet = Snippet(triggers: [":x"], content: "{{f.pick}}",
                              variables: [Variable(name: "f", kind: .form(fields: [field]))],
                              unmapped: ["var:f.fields.pick.values.0.id": "\"affirmative\""])
        let text = exported([snippet])

        #expect(text.contains("""
                            - label: "Yes please"
                              id: "affirmative"
            """), "\(text)")
        #expect(!text.contains("values.0.id"), "\(text)")
    }

    @Test("A regex that arrived with a trigger beside it goes back out with both")
    func writesTheConflictItWasGiven() {
        let snippet = Snippet(regexTrigger: ":a(.*)", content: "y", unmapped: ["trigger": "\":a\""])
        let text = exported([snippet])
        #expect(text.contains("regex: \":a(.*)\""), "\(text)")
        #expect(text.contains("trigger: \":a\""), "\(text)")
    }

    @Test("A kept key is never written twice, whatever the model holds beside it")
    func neverWritesAKeyTwice() {
        let snippet = Snippet(triggers: [":x"], label: "L", content: "y",
                              unmapped: ["label": "- a list"])
        let text = exported([snippet])
        #expect(text.components(separatedBy: "label:").count == 2, "\(text)")
        #expect(text.contains("label:\n      - a list"), "\(text)")
    }

    @Test("A fragment with nowhere left to graft is written under its own name rather than dropped")
    func keepsOrphanedFragments() throws {
        let kept = ["var:ghost.locale": "\"fr-FR\""]
        let text = exported([Snippet(triggers: [":x"], content: "y", unmapped: kept)])
        try withTemporaryDirectory { directory in
            let url = try write(text, to: "orphan.yml", in: directory)
            let read = try snippet(":x", in: group(named: "orphan",
                                                   in: EspansoImporter.importFiles([url])))
            #expect(read.unmapped == kept)
        }
    }

    // MARK: Bodies

    @Test("A match whose body is a kept key of Espanso's own is not given an empty `replace`")
    func leavesForeignBodiesAlone() {
        let text = exported([Snippet(triggers: [":x"], unmapped: ["html": "\"<b>hi</b>\""])])
        #expect(!text.contains("replace:"), "\(text)")
        // A match with nothing else to type still gets one, so the file stays valid Espanso.
        #expect(exported([Snippet(triggers: [":x"])]).contains("replace: \"\""))
    }

    @Test("The cursor marker and every token in the content pass through untouched")
    func writesContentVerbatim() throws {
        let content = "Kind regards,\n$|$\n{{company}} — {{form.name}}\ttabbed"
        try withTemporaryDirectory { directory in
            let url = try write(exported([Snippet(triggers: [":x"], content: content)]),
                                to: "content.yml", in: directory)
            let read = try snippet(":x", in: group(named: "content",
                                                   in: EspansoImporter.importFiles([url])))
            #expect(read.content == content)
        }
    }

    @Test("Text the user wrote is quoted, so a trigger of `no` cannot come back a boolean")
    func quotesEverythingTheUserWrote() throws {
        let echo = Variable(name: "on", kind: .echo(value: "off"))
        let built = Snippet(triggers: ["no"], label: "123", content: "yes", variables: [echo])
        try withTemporaryDirectory { directory in
            let url = try write(exported([built]), to: "quoted.yml", in: directory)
            let read = try snippet("no", in: group(named: "quoted",
                                                   in: EspansoImporter.importFiles([url])))
            #expect(read.label == "123")
            #expect(read.content == "yes")
            #expect(read.variables.map(VariableShape.init) == [VariableShape(echo)])
        }
    }
}
