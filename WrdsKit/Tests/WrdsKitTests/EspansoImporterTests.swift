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
        .appendingPathComponent("EspansoImporterTests-\(UUID().uuidString)", isDirectory: true)
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

// MARK: Reaching into a result

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

@Suite("EspansoImporter")
struct EspansoImporterTests {

    // MARK: Files, groups and atomicity

    @Test("Groups are named after the file stems, in the order the files were given")
    func namesGroupsAfterFileStems() throws {
        let result = try EspansoImporter.importFiles([fixture("exotic"), fixture("base")])
        #expect(result.groups.map(\.name) == ["exotic", "base"])
    }

    @Test("Two files with the same stem become 'base' and 'base 2', and the rename is reported")
    func suffixesDuplicateGroupNames() throws {
        try withTemporaryDirectory { directory in
            let first = directory.appendingPathComponent("one", isDirectory: true)
            let second = directory.appendingPathComponent("two", isDirectory: true)
            for sub in [first, second] {
                try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
                try write("matches:\n  - trigger: \":x\"\n    replace: \"y\"\n", to: "base.yml", in: sub)
            }
            let result = try EspansoImporter.importFiles([
                first.appendingPathComponent("base.yml"),
                second.appendingPathComponent("base.yml"),
            ])
            #expect(result.groups.map(\.name) == ["base", "base 2"])
            #expect(result.unmappedReport.contains { $0.contains("base 2") })
        }
    }

    @Test("A file that is not YAML is the caller's mistake, and throws")
    func throwsOnNonYAMLExtension() throws {
        try withTemporaryDirectory { directory in
            let url = try write("matches: []\n", to: "notes.txt", in: directory)
            #expect(throws: EspansoImportError.notAMatchFile(url)) {
                try EspansoImporter.importFiles([url])
            }
        }
    }

    @Test("A .yaml file is a match file too")
    func acceptsTheYAMLExtension() throws {
        try withTemporaryDirectory { directory in
            let url = try write("matches:\n  - trigger: \":x\"\n    replace: \"y\"\n",
                                to: "extra.yaml", in: directory)
            let result = try EspansoImporter.importFiles([url])
            #expect(result.groups.map(\.name) == ["extra"])
        }
    }

    @Test("A file that cannot be read throws")
    func throwsOnMissingFile() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("gone.yml", isDirectory: false)
            #expect(throws: EspansoImportError.unreadable(url)) {
                try EspansoImporter.importFiles([url])
            }
        }
    }

    @Test("One malformed file fails the whole import — nothing partial comes back")
    func throwsOnMalformedYAML() throws {
        try withTemporaryDirectory { directory in
            let broken = try write("matches:\n  - trigger: \":x\"\n   replace: [unclosed\n",
                                   to: "broken.yml", in: directory)
            var thrown: EspansoImportError?
            #expect(throws: EspansoImportError.self) {
                do {
                    _ = try EspansoImporter.importFiles([fixture("base"), broken])
                } catch let error as EspansoImportError {
                    thrown = error
                    throw error
                }
            }
            guard case .malformed(let file, _) = try #require(thrown) else {
                Issue.record("expected .malformed, got \(String(describing: thrown))")
                return
            }
            #expect(file == "broken.yml")
        }
    }

    @Test("A match file whose root is not a mapping is malformed")
    func throwsOnNonMappingRoot() throws {
        try withTemporaryDirectory { directory in
            let url = try write("- just\n- a\n- list\n", to: "odd.yml", in: directory)
            #expect(throws: EspansoImportError.self) {
                try EspansoImporter.importFiles([url])
            }
        }
    }

    @Test("A match file whose `matches` is not a list is malformed")
    func throwsOnNonListMatches() throws {
        try withTemporaryDirectory { directory in
            let url = try write("matches:\n  trigger: \":x\"\n", to: "odd.yml", in: directory)
            #expect(throws: EspansoImportError.self) {
                try EspansoImporter.importFiles([url])
            }
        }
    }

    @Test("Underscore-prefixed files are Espanso plumbing: skipped, and said so")
    func skipsUnderscorePrefixedFiles() throws {
        try withTemporaryDirectory { directory in
            let manifest = try write("name: some-package\nversion: 1.0.0\n",
                                     to: "_manifest.yml", in: directory)
            let result = try EspansoImporter.importFiles([manifest, fixture("base")])
            #expect(result.groups.map(\.name) == ["base"])
            #expect(result.unmappedReport.contains { $0.hasPrefix("_manifest.yml:") })
        }
    }

    @Test("An empty file is an empty group, not an error")
    func emptyFileBecomesAnEmptyGroup() throws {
        try withTemporaryDirectory { directory in
            let url = try write("# nothing here yet\n", to: "blank.yml", in: directory)
            let result = try EspansoImporter.importFiles([url])
            #expect(result.groups.count == 1)
            #expect(try #require(result.groups.first).snippets.isEmpty)
        }
    }

    @Test("Importing no files at all is an empty result")
    func importsNothingFromNoFiles() throws {
        let result = try EspansoImporter.importFiles([])
        #expect(result.groups.isEmpty)
        #expect(result.globals.isEmpty)
        #expect(result.unmappedReport.isEmpty)
    }

    @Test("A top-level key that is neither matches nor global_vars is reported as dropped")
    func reportsDroppedTopLevelKeys() throws {
        try withTemporaryDirectory { directory in
            let url = try write("filter_title: \"Chrome\"\nmatches: []\n", to: "filtered.yml",
                                in: directory)
            let result = try EspansoImporter.importFiles([url])
            #expect(result.unmappedReport == [
                "filtered.yml: dropped unsupported top-level key 'filter_title'",
            ])
        }
    }

    @Test("Sections with nothing under them are empty, not broken")
    func toleratesEmptySections() throws {
        try withTemporaryDirectory { directory in
            // A half-written file must not fail the migration of the directory it sits in.
            let stub = try write("matches:\nglobal_vars:\n", to: "stub.yml", in: directory)
            let bare = try write("""
                matches:
                  - trigger: ":x"
                    replace: "y"
                    vars:
                """, to: "bare.yml", in: directory)
            let result = try EspansoImporter.importFiles([stub, bare])
            #expect(result.groups.map(\.name) == ["stub", "bare"])
            #expect(try group(named: "stub", in: result).snippets.isEmpty)
            #expect(result.globals.isEmpty)
            #expect(try snippet(":x", in: group(named: "bare", in: result)).variables.isEmpty)
            #expect(result.unmappedReport.isEmpty)
        }
    }

    @Test("A section of the wrong type is still a broken file")
    func throwsOnWrongTypedSections() throws {
        try withTemporaryDirectory { directory in
            let url = try write("""
                matches:
                  - trigger: ":x"
                    replace: "y"
                    vars:
                      name: not a list
                """, to: "odd.yml", in: directory)
            #expect(throws: EspansoImportError.self) { try EspansoImporter.importFiles([url]) }
        }
    }

    @Test("The default match directory agrees with the filesystem")
    func defaultMatchDirectoryAgreesWithDisk() {
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/espanso/match", isDirectory: true)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: expected.path, isDirectory: &isDirectory)
        if exists && isDirectory.boolValue {
            #expect(EspansoImporter.defaultEspansoMatchDirectory() == expected)
        } else {
            #expect(EspansoImporter.defaultEspansoMatchDirectory() == nil)
        }
    }

    // MARK: base.yml: the mapped surface

    @Test("A plain match keeps its label, its content and its cursor marker verbatim")
    func mapsPlainReplace() throws {
        let base = try group(named: "base", in: EspansoImporter.importFiles([fixture("base")]))
        let sig = try snippet(":sig", in: base)
        #expect(sig.triggers == [":sig"])
        #expect(sig.regexTrigger == nil)
        #expect(sig.label == "Sign off")
        #expect(sig.content == "Kind regards,\n$|$\nThomas")
        #expect(sig.wordBoundary == false)
        #expect(sig.propagateCase == false)
        #expect(sig.uppercaseStyle == nil)
        #expect(sig.variables.isEmpty)
        #expect(sig.isEnabled)
    }

    @Test("`triggers` and `word` map to several triggers and a word boundary")
    func mapsMultipleTriggersAndWordBoundary() throws {
        let base = try group(named: "base", in: EspansoImporter.importFiles([fixture("base")]))
        let addr = try snippet(":addr", in: base)
        #expect(addr.triggers == [":addr", ":address"])
        #expect(addr.wordBoundary)
        #expect(addr.label.isEmpty)
    }

    @Test("`propagate_case` and `uppercase_style: capitalize_words` map across")
    func mapsCasePropagation() throws {
        let base = try group(named: "base", in: EspansoImporter.importFiles([fixture("base")]))
        let thanks = try snippet(":ty", in: base)
        #expect(thanks.propagateCase)
        #expect(thanks.uppercaseStyle == .capitaliseWords)
    }

    @Test("The other two uppercase styles map, and an unknown one is kept rather than guessed at")
    func mapsTheUppercaseStyleTable() throws {
        try withTemporaryDirectory { directory in
            let url = try write("""
                matches:
                  - trigger: ":a"
                    replace: "a"
                    uppercase_style: capitalize
                  - trigger: ":b"
                    replace: "b"
                    uppercase_style: uppercase
                  - trigger: ":c"
                    replace: "c"
                    uppercase_style: shouty
                """, to: "styles.yml", in: directory)
            let styles = try group(named: "styles", in: EspansoImporter.importFiles([url]))
            #expect(try snippet(":a", in: styles).uppercaseStyle == .capitalise)
            #expect(try snippet(":b", in: styles).uppercaseStyle == .uppercase)
            let unknown = try snippet(":c", in: styles)
            #expect(unknown.uppercaseStyle == nil)
            #expect(unknown.unmapped["uppercase_style"] == "shouty")
            #expect(styles.snippets.count == 3)
        }
    }

    @Test("A date variable keeps its format, and its offset in seconds")
    func mapsDateVariable() throws {
        let base = try group(named: "base", in: EspansoImporter.importFiles([fixture("base")]))
        let log = try snippet(":log", in: base)
        #expect(try variable("yesterday", in: log).kind
            == .date(format: "%Y-%m-%d", offsetSeconds: -86_400))
    }

    @Test("A shell variable keeps its command and is given a timeout Espanso never had")
    func mapsShellVariable() throws {
        let base = try group(named: "base", in: EspansoImporter.importFiles([fixture("base")]))
        let log = try snippet(":log", in: base)
        #expect(try variable("branch", in: log).kind
            == .shell(command: "git rev-parse --abbrev-ref HEAD", timeoutSeconds: 10))
    }

    @Test("The imported shell timeout is a budget the runner treats as a deadline")
    func importedShellTimeoutIsASaneBudget() throws {
        // A timeout past roughly a century makes `ShellRunner` wait without a deadline at all, and a
        // zero or negative one kills the command before it starts. Import is one of the edges where a
        // value reaches the expansion path, so what it produces has to sit inside (0, 3600].
        let base = try group(named: "base", in: EspansoImporter.importFiles([fixture("base")]))
        let log = try snippet(":log", in: base)
        guard case .shell(_, let timeout) = try variable("branch", in: log).kind else {
            Issue.record("expected a shell variable")
            return
        }
        #expect(timeout > 0)
        #expect(timeout <= 3600)
    }

    @Test("Choice and clipboard variables map by type")
    func mapsChoiceAndClipboardVariables() throws {
        let base = try group(named: "base", in: EspansoImporter.importFiles([fixture("base")]))
        let ship = try snippet(":ship", in: base)
        #expect(try variable("flavour", in: ship).kind == .choice(options: ["alpha", "beta"]))
        #expect(try variable("clip", in: ship).kind == .clipboard)
    }

    @Test("`random` is `choice` under another name, and takes `choices` as well as `values`")
    func mapsRandomVariable() throws {
        try withTemporaryDirectory { directory in
            let url = try write("""
                matches:
                  - trigger: ":r"
                    replace: "{{pick}}"
                    vars:
                      - name: pick
                        type: random
                        params:
                          choices:
                            - "heads"
                            - "tails"
                """, to: "random.yml", in: directory)
            let random = try group(named: "random", in: EspansoImporter.importFiles([url]))
            let match = try snippet(":r", in: random)
            #expect(try variable("pick", in: match).kind == .choice(options: ["heads", "tails"]))
            #expect(match.unmapped.isEmpty)
        }
    }

    @Test("A parameter of a shape the mapping cannot use is kept, not quietly defaulted")
    func keepsParametersOfTheWrongShape() throws {
        try withTemporaryDirectory { directory in
            let url = try write("""
                matches:
                  - trigger: ":odd"
                    label:
                      - a list
                    replace: "{{when}}"
                    vars:
                      - name: when
                        type: date
                        params:
                          format: "%H"
                          offset: "an hour"
                """, to: "odd.yml", in: directory)
            let odd = try snippet(":odd", in: group(named: "odd",
                                                    in: EspansoImporter.importFiles([url])))
            #expect(try variable("when", in: odd).kind == .date(format: "%H", offsetSeconds: 0))
            #expect(odd.unmapped["var:when.offset"] == "\"an hour\"")
            #expect(odd.unmapped["label"] == "- a list")
            #expect(odd.label.isEmpty)
        }
    }

    @Test("Wrong-shaped variable parameters are kept beside the variables they belong to")
    func keepsWrongShapedVariableParameters() throws {
        try withTemporaryDirectory { directory in
            let url = try write("""
                matches:
                  - trigger: ":odd"
                    replace: "{{when}} {{said}} {{ran}} {{filled}}"
                    vars:
                      - name: when
                        type: date
                        params:
                          format:
                            - "%H"
                      - name: said
                        type: echo
                        params:
                          echo:
                            - hello
                      - name: ran
                        type: shell
                        params:
                          cmd:
                            - echo
                            - hi
                      - name: filled
                        type: form
                        params:
                          layout:
                            - "[[x]]"
                """, to: "shapes.yml", in: directory)
            let odd = try snippet(":odd", in: group(named: "shapes",
                                                    in: EspansoImporter.importFiles([url])))
            #expect(odd.unmapped["var:when.format"] == "- \"%H\"")
            #expect(odd.unmapped["var:said.echo"] == "- hello")
            #expect(odd.unmapped["var:ran.cmd"] == "- echo\n- hi")
            #expect(odd.unmapped["var:filled.layout"] == "- \"[[x]]\"")
        }
    }

    @Test("A `regex:` or `form:` this cannot read is kept, and the rest of the match still maps")
    func keepsUnreadableRegexAndForm() throws {
        try withTemporaryDirectory { directory in
            let url = try write("""
                matches:
                  - trigger: ":a"
                    replace: "first"
                    regex:
                  - trigger: ":b"
                    replace: "second"
                    form:
                      - a list
                """, to: "heads.yml", in: directory)
            let heads = try group(named: "heads", in: EspansoImporter.importFiles([url]))
            let first = try snippet(":a", in: heads)
            #expect(first.regexTrigger == nil)
            #expect(first.triggers == [":a"])
            // A key with nothing under it is YAML's null, whose fragment is empty — but the key was
            // written, so it is still recorded rather than passed over.
            #expect(first.unmapped["regex"] == "")
            let second = try snippet(":b", in: heads)
            #expect(second.content == "second")
            #expect(second.variables.isEmpty)
            #expect(second.unmapped["form"] == "- a list")
        }
    }

    @Test("A list of choices this cannot read is kept whole, not turned into an empty picker")
    func keepsUnreadableChoiceValues() throws {
        try withTemporaryDirectory { directory in
            let url = try write("""
                matches:
                  - trigger: ":pick"
                    replace: "{{one}} {{two}}"
                    vars:
                      - name: one
                        type: choice
                        params:
                          values:
                            from: a file
                      - name: two
                        type: form
                        params:
                          layout: "[[colour]]"
                          fields:
                            colour:
                              type: choice
                              values:
                                from: a file
                """, to: "picks.yml", in: directory)
            let pick = try snippet(":pick", in: group(named: "picks",
                                                      in: EspansoImporter.importFiles([url])))
            #expect(try variable("one", in: pick).kind == .choice(options: []))
            #expect(pick.unmapped["var:one.values"] == "from: a file")
            #expect(pick.unmapped["var:two.fields.colour.values"] == "from: a file")
        }
    }

    @Test("A `type: form` variable's layout is inlined where the content referenced it")
    func mapsFormVariable() throws {
        let base = try group(named: "base", in: EspansoImporter.importFiles([fixture("base")]))
        let ship = try snippet(":ship", in: base)
        #expect(ship.content == "Shipping {{flavour}} — {{clip}}\n"
            + "{{details.ticket}} {{details.owner}}")
        guard case .form(let fields) = try variable("details", in: ship).kind else {
            Issue.record("expected a form variable")
            return
        }
        // Layout order, not declaration order: the layout is what the user reads.
        #expect(fields.map(\.name) == ["ticket", "owner"])
        #expect(fields.map(\.kind) == [.text(default: ""), .text(default: "Thomas")])
    }

    @Test("A match-level `form:` becomes a variable named `form`, typed by `form_fields`")
    func mapsFormShorthand() throws {
        let base = try group(named: "base", in: EspansoImporter.importFiles([fixture("base")]))
        let greet = try snippet(":greet", in: base)
        #expect(greet.content == "Hi {{form.name}},\n\n{{form.body}}\n\n{{form.urgency}}")
        guard case .form(let fields) = try variable("form", in: greet).kind else {
            Issue.record("expected a form variable")
            return
        }
        #expect(fields.map(\.name) == ["name", "body", "urgency"])
        // The third is a block scalar — one choice per line, which is how Espanso's form
        // documentation spells a list of values.
        #expect(fields.map(\.kind) == [.text(default: ""), .multiline(default: ""),
                                       .choice(options: ["Whenever", "Today"])])
        #expect(greet.unmapped.isEmpty)
    }

    @Test("A form field declared as a choice keeps its values")
    func mapsFormChoiceField() throws {
        try withTemporaryDirectory { directory in
            let url = try write("""
                matches:
                  - trigger: ":f"
                    form: "Ship to [[where]]"
                    form_fields:
                      where:
                        type: choice
                        values:
                          - "here"
                          - "there"
                """, to: "forms.yml", in: directory)
            let forms = try group(named: "forms", in: EspansoImporter.importFiles([url]))
            guard case .form(let fields) = try variable("form", in: snippet(":f", in: forms)).kind else {
                Issue.record("expected a form variable")
                return
            }
            #expect(fields.map(\.kind) == [.choice(options: ["here", "there"])])
        }
    }

    @Test("`global_vars` become globals")
    func mapsGlobalVariables() throws {
        let result = try EspansoImporter.importFiles([fixture("base")])
        #expect(result.globals.count == 1)
        #expect(result.globals.first?.variable.name == "company")
        #expect(result.globals.first?.variable.kind == .echo(value: "F Wrds"))
    }

    @Test("A global of an unknown type is dropped rather than half-imported, and said so")
    func dropsUnknownGlobalTypes() throws {
        try withTemporaryDirectory { directory in
            let url = try write("""
                global_vars:
                  - name: greeting
                    type: echo
                    params:
                      echo: "hi"
                  - name: fetched
                    type: script
                    params:
                      args: ["python3", "x.py"]
                """, to: "globals.yml", in: directory)
            let result = try EspansoImporter.importFiles([url])
            #expect(result.globals.map(\.variable.name) == ["greeting"])
            #expect(result.unmappedReport == [
                "globals.yml › global_vars: dropped unsupported variable 'fetched' of type 'script'",
            ])
        }
    }

    @Test("A date with no format is given one, and the guess is reported")
    func reportsADefaultedDateFormat() throws {
        try withTemporaryDirectory { directory in
            let url = try write("""
                matches:
                  - trigger: ":now"
                    replace: "{{stamp}}"
                    vars:
                      - name: stamp
                        type: date
                """, to: "dates.yml", in: directory)
            let result = try EspansoImporter.importFiles([url])
            let now = try snippet(":now", in: group(named: "dates", in: result))
            #expect(try variable("stamp", in: now).kind == .date(format: "%Y-%m-%d", offsetSeconds: 0))
            #expect(now.unmapped.isEmpty)
            #expect(result.unmappedReport == [
                "dates.yml › :now: no format on date variable 'stamp'; used '%Y-%m-%d'",
            ])
        }
    }

    @Test("A form field of an unknown type keeps the type it was given")
    func keepsUnknownFormFieldTypes() throws {
        try withTemporaryDirectory { directory in
            let url = try write("""
                matches:
                  - trigger: ":f"
                    form: "Pick [[colour]]"
                    form_fields:
                      colour:
                        type: swatch
                """, to: "fields.yml", in: directory)
            let fields = try group(named: "fields", in: EspansoImporter.importFiles([url]))
            let match = try snippet(":f", in: fields)
            #expect(match.unmapped["var:form.fields.colour.type"] == "swatch")
        }
    }

    @Test("Nothing in base.yml is left over: no unmapped entries, and an empty report")
    func mapsEveryKeyInBase() throws {
        let result = try EspansoImporter.importFiles([fixture("base")])
        let base = try group(named: "base", in: result)
        #expect(base.snippets.count == 6)
        for snippet in base.snippets {
            #expect(snippet.unmapped.isEmpty, "\(snippet.triggers) kept \(snippet.unmapped)")
        }
        #expect(result.unmappedReport.isEmpty, "\(result.unmappedReport)")
    }

    // MARK: exotic.yml: what survives

    @Test("An unsupported match key is kept verbatim and reported in the plan's own wording")
    func keepsUnsupportedMatchKeys() throws {
        let result = try EspansoImporter.importFiles([fixture("exotic")])
        let exotic = try group(named: "exotic", in: result)
        // Quoted because the fragment is YAML, not a value: the quoting is what tells a re-export
        // that this was a string rather than something YAML would read as a number or a boolean.
        #expect(try snippet(":pic", in: exotic).unmapped["image_path"]
            == "\"$CONFIG/images/logo.png\"")
        #expect(result.unmappedReport.contains(
            "exotic.yml › :pic: kept unsupported key 'image_path'"))
    }

    @Test("Rich-text bodies survive as raw YAML")
    func keepsRichTextBodies() throws {
        let exotic = try group(named: "exotic", in: EspansoImporter.importFiles([fixture("exotic")]))
        let bold = try snippet(":bold", in: exotic)
        #expect(bold.unmapped["html"] == "\"<b>hello</b>\"")
        #expect(bold.unmapped["markdown"] == "\"**hello**\"")
        #expect(bold.content.isEmpty)
    }

    @Test("A structured unsupported key keeps its structure")
    func keepsStructuredUnsupportedKeys() throws {
        let exotic = try group(named: "exotic", in: EspansoImporter.importFiles([fixture("exotic")]))
        let greet = try #require(exotic.snippets.first { $0.regexTrigger != nil })
        #expect(greet.unmapped["search_terms"] == "- greeting\n- hello")
    }

    @Test("`left_word` is not `word`, and is kept rather than approximated")
    func keepsLeftWord() throws {
        let exotic = try group(named: "exotic", in: EspansoImporter.importFiles([fixture("exotic")]))
        let when = try snippet(":when", in: exotic)
        #expect(when.unmapped["left_word"] == "true")
        #expect(when.wordBoundary == false)
    }

    @Test("An unknown variable type is kept whole, and its token is left in the content")
    func keepsUnknownVariableTypes() throws {
        let result = try EspansoImporter.importFiles([fixture("exotic")])
        let exotic = try group(named: "exotic", in: result)
        let ip = try snippet(":ip", in: exotic)
        #expect(ip.variables.isEmpty)
        // Byte for byte, structure and all — this is the fragment an export has to put back.
        #expect(ip.unmapped["var:ip"] == """
            name: ip
            type: script
            params:
              args:
              - python3
              - fetch_ip.py
            """)
        #expect(ip.content == "{{ip}}")
        #expect(result.unmappedReport.contains(
            "exotic.yml › :ip: kept unsupported variable 'ip' of type 'script'"))
    }

    @Test("A regex beats a literal trigger, and the trigger is kept rather than dropped")
    func keepsATriggerThatLosesToARegex() throws {
        let result = try EspansoImporter.importFiles([fixture("exotic")])
        let exotic = try group(named: "exotic", in: result)
        let greet = try #require(exotic.snippets.first { $0.regexTrigger != nil })
        #expect(greet.regexTrigger == ":greet(?P<name>.*)\\.")
        #expect(greet.triggers.isEmpty)
        #expect(greet.unmapped["trigger"] == "\":greet\"")
        #expect(result.unmappedReport.contains { $0.contains("kept 'trigger' alongside 'regex'") })
    }

    @Test("A parameter that cannot be represented is kept beside its variable, not instead of it")
    func keepsUnrepresentableParameters() throws {
        let result = try EspansoImporter.importFiles([fixture("exotic")])
        let exotic = try group(named: "exotic", in: result)
        let when = try snippet(":when", in: exotic)
        #expect(try variable("stamp", in: when).kind == .date(format: "%H:%M", offsetSeconds: 0))
        #expect(when.unmapped["var:stamp.locale"] == "\"fr-FR\"")
        #expect(result.unmappedReport.contains(
            "exotic.yml › :when: kept unsupported parameter 'locale' of variable 'stamp'"))
    }

    @Test("Choice values written as objects map by their label, and their ids are kept")
    func mapsObjectChoiceValues() throws {
        let exotic = try group(named: "exotic", in: EspansoImporter.importFiles([fixture("exotic")]))
        let when = try snippet(":when", in: exotic)
        #expect(try variable("pick", in: when).kind
            == .choice(options: ["Yes please", "No thanks"]))
        #expect(when.unmapped["var:pick.values.0.id"] == "\"affirmative\"")
    }

    @Test("A form that maps keeps the spellings and the wording that do not")
    func keepsFormWordingAndSpellings() throws {
        let result = try EspansoImporter.importFiles([fixture("exotic")])
        let exotic = try group(named: "exotic", in: result)
        let brief = try snippet(":brief", in: exotic)
        // The form itself maps: fields in layout order, `list` read as the choice it is.
        guard case .form(let fields) = try variable("brief", in: brief).kind else {
            Issue.record("expected a form variable")
            return
        }
        #expect(fields.map(\.name) == ["client", "scope"])
        #expect(fields.map(\.kind) == [.choice(options: ["Acme", "Globex"]),
                                       .multiline(default: "")])
        #expect(brief.content == "Brief for {{brief.client}}:\n{{brief.scope}}")
        // And what does not map is kept: the panel's wording, the `list` spelling, and a
        // `default:` on a kind that has nowhere to put one.
        #expect(brief.unmapped["var:brief.layout"] == "\"Brief for [[client]]:\\n[[scope]]\"")
        #expect(brief.unmapped["var:brief.fields.client.type"] == "list")
        #expect(brief.unmapped["var:brief.fields.client.default"] == "\"Acme\"")
        #expect(result.unmappedReport.contains(
            "exotic.yml › :brief: kept the wording of the layout of form 'brief'"))
        #expect(result.unmappedReport.contains(
            "exotic.yml › :brief: kept unsupported parameter 'fields.client.type' of variable 'brief'"))
    }

    @Test("Every kept key is named in the report exactly once")
    func reportsEveryKeptKey() throws {
        let result = try EspansoImporter.importFiles([fixture("exotic")])
        let exotic = try group(named: "exotic", in: result)
        let kept = exotic.snippets.reduce(0) { $0 + $1.unmapped.count }
        #expect(kept == 12, "\(exotic.snippets.map(\.unmapped))")
        #expect(result.unmappedReport.count == kept, "\(result.unmappedReport)")
        #expect(result.unmappedReport.allSatisfy { $0.hasPrefix("exotic.yml › ") })
    }
}
