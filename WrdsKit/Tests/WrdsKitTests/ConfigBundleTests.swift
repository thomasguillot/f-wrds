import Foundation
import Testing
import WrdsKit

/// Reads encoded bytes back as raw JSON, so tests assert on the shape of the file the user ends up
/// holding rather than on a round trip through the same coder that produced it.
private func jsonObject(_ data: Data) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: data)
    return try #require(object as? [String: Any], "expected the bundle to be a JSON object")
}

/// A file the user might pick from a file panel that is not an F Wrds backup.
private struct Junk: Sendable, CustomStringConvertible {
    let why: String
    let text: String

    var data: Data { Data(text.utf8) }
    var description: String { why }
}

@Suite("ConfigBundle")
struct ConfigBundleTests {

    // MARK: Fixture

    // Fixed identities, so a test can assert that the very same UUID comes back — the pinned-snippet
    // list is a list of references into the groups, and a backup that renumbered them would restore
    // a configuration that no longer points at itself.
    private static let signaturesGroupID = UUID()
    private static let emptyGroupID = UUID()
    private static let pinnedSnippetID = UUID()
    private static let globalID = UUID()

    /// A configuration exercising every field the model can hold, each moved off its default, so a
    /// round trip that drops one is caught.
    ///
    /// Built once, not per call: `Variable` and `FormField` default their IDs to a fresh `UUID()`,
    /// so a function would hand out a *different* configuration each time and no comparison against
    /// it would mean anything.
    private static let fullyPopulatedGroups: [SnippetGroup] = [
        SnippetGroup(
            id: signaturesGroupID,
            name: "Signatures",
            snippets: [
                Snippet(
                    id: pinnedSnippetID,
                    triggers: [":sig", ":sign"],
                    label: "Email signature",
                    content: "Best,\n{{today}} {{brief.client}} $|$",
                    wordBoundary: true,
                    propagateCase: true,
                    uppercaseStyle: .capitaliseWords,
                    variables: [
                        Variable(name: "today", kind: .date(format: "%Y-%m-%d", offsetSeconds: -86_400)),
                        Variable(name: "clip", kind: .clipboard),
                        Variable(name: "pick", kind: .choice(options: ["one", "two"])),
                        Variable(name: "hello", kind: .echo(value: "hi")),
                        Variable(name: "branch",
                                 kind: .shell(command: "git branch --show-current",
                                              timeoutSeconds: 2.5)),
                        Variable(name: "brief", kind: .form(fields: [
                            FormField(name: "client", label: "Client", kind: .text(default: "Acme")),
                            FormField(name: "scope", label: "Scope", kind: .multiline(default: "")),
                            FormField(name: "tier", label: "Tier",
                                      kind: .choice(options: ["free", "paid"])),
                        ])),
                        Variable(name: "signoff", kind: .global(name: "signoff")),
                    ],
                    isEnabled: false,
                    unmapped: ["image_path": "/tmp/pic.png", "var:script": "type: script"]),
                Snippet(regexTrigger: ":d(?<n>\\d+)", content: "day {{n}}"),
            ],
            onlyInApps: ["com.apple.Mail"],
            neverInApps: ["com.apple.Terminal"],
            isEnabled: false),
        SnippetGroup(id: emptyGroupID, name: "Empty"),
    ]

    private static let fullyPopulatedGlobals: [GlobalVariable] = [
        GlobalVariable(id: globalID, variable: Variable(name: "signoff", kind: .echo(value: "— Thomas"))),
    ]

    /// Every settings field moved off its default, including both hot keys and a pinned snippet that
    /// names a snippet in `fullyPopulatedGroups`.
    private static let fullyPopulatedSettings: AppSettings = {
        var settings = AppSettings.default
        settings.engineEnabled = false
        settings.undoOnBackspace = false
        settings.pickerHotKey = HotKeySpec(keyCode: 36, modifiers: 0x0100)
        settings.pauseHotKey = HotKeySpec(keyCode: 53, modifiers: 0x1000)
        settings.defaultInjectionMode = .typed
        settings.perAppInjectionOverrides = ["com.apple.Terminal": .typed, "com.apple.Safari": .paste]
        settings.showDockIcon = true
        settings.launchAtLogin = true
        settings.languageOverride = "en-GB"
        settings.checkForUpdatesAutomatically = false
        settings.pinnedSnippetIDs = [pinnedSnippetID]
        return settings
    }()

    /// The fixture as backup bytes.
    private static func encoded() throws -> Data {
        try ConfigBundle.encode(groups: fullyPopulatedGroups, globals: fullyPopulatedGlobals,
                                settings: fullyPopulatedSettings)
    }

    /// The fixture, encoded and read straight back — the path every restore takes.
    private static func roundTripped() throws -> ConfigBundle {
        try ConfigBundle.decode(encoded())
    }

    // MARK: Round trip

    @Test("Every group, global and setting survives an encode and a decode")
    func roundTripsTheWholeConfiguration() throws {
        let bundle = try Self.roundTripped()

        #expect(bundle.version == 1)
        #expect(bundle.groups == Self.fullyPopulatedGroups)
        #expect(bundle.globals == Self.fullyPopulatedGlobals)
        #expect(bundle.settings == Self.fullyPopulatedSettings)
    }

    @Test("Both hot keys and the pinned list come back exactly as they went in")
    func roundTripsSettingsThatOtherFormatsWouldFlatten() throws {
        let settings = try Self.roundTripped().settings

        #expect(settings.pickerHotKey == HotKeySpec(keyCode: 36, modifiers: 0x0100))
        #expect(settings.pauseHotKey == HotKeySpec(keyCode: 53, modifiers: 0x1000))
        #expect(settings.pinnedSnippetIDs == [Self.pinnedSnippetID])
        #expect(settings.perAppInjectionOverrides["com.apple.Terminal"] == .typed)
        #expect(settings.perAppInjectionOverrides["com.apple.Safari"] == .paste)
        #expect(settings.languageOverride == "en-GB")
    }

    @Test("The identities that cross-reference each other survive, so a pinned snippet stays pinned")
    func keepsTheIdentitiesThatCrossReference() throws {
        let bundle = try Self.roundTripped()

        let pinned = try #require(bundle.settings.pinnedSnippetIDs.first)
        #expect(pinned == Self.pinnedSnippetID)
        #expect(bundle.groups.flatMap(\.snippets).contains { $0.id == pinned },
                "a pinned ID that no longer names a snippet is a restore that lost the reference")
        #expect(bundle.groups.map(\.id) == [Self.signaturesGroupID, Self.emptyGroupID])
        #expect(bundle.globals.map(\.id) == [Self.globalID])
    }

    @Test("What an Espanso export has to drop is exactly what a backup keeps")
    func keepsWhatTheEspansoBorderCannotHold() throws {
        let bundle = try Self.roundTripped()

        let group = try #require(bundle.groups.first)
        #expect(group.isEnabled == false)
        #expect(group.onlyInApps == ["com.apple.Mail"])
        #expect(group.neverInApps == ["com.apple.Terminal"])

        let snippet = try #require(group.snippets.first)
        #expect(snippet.isEnabled == false)
        #expect(snippet.unmapped == ["image_path": "/tmp/pic.png", "var:script": "type: script"])

        // Espanso has no per-variable timeout, so the exporter never writes one. A backup does.
        let shell = try #require(snippet.variables.first { $0.name == "branch" })
        guard case .shell(let command, let timeoutSeconds) = shell.kind else {
            Issue.record("expected the shell variable to come back as a shell variable")
            return
        }
        #expect(command == "git branch --show-current")
        #expect(timeoutSeconds == 2.5)
    }

    @Test("Every variable kind comes back as the kind it was")
    func roundTripsTheVariableVocabulary() throws {
        let bundle = try Self.roundTripped()
        let snippet = try #require(bundle.groups.first?.snippets.first)

        let original = Self.fullyPopulatedGroups[0].snippets[0].variables
        #expect(snippet.variables.map(\.name)
            == ["today", "clip", "pick", "hello", "branch", "brief", "signoff"])
        #expect(snippet.variables.map(\.kind) == original.map(\.kind))
        #expect(snippet.content == "Best,\n{{today}} {{brief.client}} $|$",
                "the cursor marker and every token are content, and stay verbatim")
        #expect(snippet.uppercaseStyle == .capitaliseWords)
        #expect(bundle.groups[0].snippets[1].regexTrigger == ":d(?<n>\\d+)")
    }

    @Test("A configuration with nothing in it round-trips as nothing rather than as a failure")
    func roundTripsAnEmptyConfiguration() throws {
        let data = try ConfigBundle.encode(groups: [], globals: [], settings: .default)
        let bundle = try ConfigBundle.decode(data)

        #expect(bundle.groups.isEmpty)
        #expect(bundle.globals.isEmpty)
        #expect(bundle.settings == .default)
        #expect(bundle.version == 1)
    }

    // MARK: The file itself

    @Test("An encoded bundle carries this build's version beside the whole configuration")
    func stampsTheCurrentVersion() throws {
        let object = try jsonObject(Self.encoded())

        #expect(ConfigBundle.currentVersion == 1, "bumping this is a migration, not a tidy-up")
        #expect(object["version"] as? Int == 1)
        #expect((object["groups"] as? [Any])?.count == 2)
        #expect((object["globals"] as? [Any])?.count == 1)
        let settings = try #require(object["settings"] as? [String: Any])
        #expect(settings["defaultInjectionMode"] as? String == "typed")
    }

    @Test("The backup is pretty-printed with sorted keys — it is a file people open")
    func writesReadableJSON() throws {
        let text = try String(decoding: Self.encoded(), as: UTF8.self)

        #expect(text.contains("\n  \"version\" : 1"), "pretty-printed, one key per line")

        let order = try ["globals", "groups", "settings", "version"].map { key in
            try #require(text.range(of: "\"\(key)\"")?.lowerBound, "expected a top-level \(key) key")
        }
        #expect(order == order.sorted(), "the top-level keys come out in sorted order")
    }

    @Test("The same configuration always gives the same bytes")
    func writesDeterministically() throws {
        // The configuration holds two dictionaries — `unmapped` and `perAppInjectionOverrides` —
        // whose ordering is arbitrary unless the encoder sorts keys. This is the test that says it does.
        let bytes = try (0..<5).map { _ in try Self.encoded() }

        #expect(Set(bytes).count == 1, "a backup that churns is one nobody can keep in version control")
    }

    // MARK: Refusals

    @Test("Bytes that are not an F Wrds backup are refused", arguments: [
        Junk(why: "not JSON at all", text: "not a backup at all ⚠️"),
        Junk(why: "empty", text: ""),
        Junk(why: "JSON, but not an object", text: "[1, 2, 3]"),
        Junk(why: "an object with nothing in it", text: "{}"),
        Junk(why: "a version and nothing else", text: #"{"version":1}"#),
        Junk(why: "a version that is not a number",
             text: #"{"version":"one","groups":[],"globals":[],"settings":{}}"#),
        Junk(why: "truncated mid-write", text: #"{"version":1,"groups":[{"id":"#),
        Junk(why: "a group that is not a group",
             text: #"{"version":1,"groups":[7],"globals":[],"settings":{}}"#),
    ])
    fileprivate func refusesBytesThatAreNotABundle(_ junk: Junk) {
        #expect(throws: ConfigBundle.ImportError.malformed) { try ConfigBundle.decode(junk.data) }
    }

    @Test("A bundle missing a whole section is corruption, not an empty section", arguments: [
        Junk(why: "no settings", text: #"{"version":1,"groups":[],"globals":[]}"#),
        Junk(why: "no groups", text: #"{"version":1,"globals":[],"settings":{}}"#),
        Junk(why: "no globals", text: #"{"version":1,"groups":[],"settings":{}}"#),
    ])
    fileprivate func refusesBundlesMissingASection(_ junk: Junk) {
        // Defaulting an absent section to "empty" would restore a configuration the file never
        // described — silently deleting every group, or every global, from a half-written backup.
        #expect(throws: ConfigBundle.ImportError.malformed) { try ConfigBundle.decode(junk.data) }
    }

    @Test("A bundle from a newer F Wrds is refused by version rather than read", arguments: [2, 3, 99])
    func refusesVersionsThisBuildDoesNotKnow(_ version: Int) {
        let future = Data(#"{"version":\#(version),"groups":[],"globals":[],"settings":{}}"#.utf8)

        #expect(throws: ConfigBundle.ImportError.unsupportedVersion(version)) {
            try ConfigBundle.decode(future)
        }
    }

    @Test("A version below this build's is refused too, rather than read as if it were current")
    func refusesVersionsBelowTheCurrentOne() {
        let ancient = Data(#"{"version":0,"groups":[],"globals":[],"settings":{}}"#.utf8)

        #expect(throws: ConfigBundle.ImportError.unsupportedVersion(0)) { try ConfigBundle.decode(ancient) }
    }

    @Test("The version is read before the payload, so a newer backup is not called corrupt")
    func readsTheVersionBeforeThePayload() {
        // Payloads of a shape this build cannot decode at all, under a version it does not know. The
        // version has to win: "your backup is from a newer F Wrds" is actionable, "your backup is
        // corrupt" is both wrong and alarming.
        let future = Data(#"{"version":99,"groups":"a shape this build has never seen","settings":7}"#.utf8)

        #expect(throws: ConfigBundle.ImportError.unsupportedVersion(99)) { try ConfigBundle.decode(future) }
    }

    // MARK: Seams

    @Test("Settings keep their per-key leniency inside a bundle")
    func settingsStayLenientKeyByKey() throws {
        let partial = Data(#"{"version":1,"groups":[],"globals":[],"settings":{"showDockIcon":true}}"#.utf8)

        let bundle = try ConfigBundle.decode(partial)

        #expect(bundle.settings.showDockIcon)
        #expect(bundle.settings.engineEnabled, "an absent key must not flip a default")
        #expect(bundle.settings.defaultInjectionMode == .paste)
        // Optionals are the exception, exactly as in settings.json: absence reads as "cleared",
        // because omitting the key is how clearing a hot key is stored.
        #expect(bundle.settings.pickerHotKey == nil)
    }

    @Test("A timeout that is not a number refuses to be written rather than crashing the export")
    func refusesToWriteATimeoutJSONCannotHold() {
        // `Variable.Kind.shell` carries the only `Double` in the bundle, and JSON has no spelling for
        // a non-finite one — JSONEncoder throws `EncodingError.invalidValue` rather than inventing
        // one. That is the whole reason `encode` throws; a `try!` here would crash the app on export.
        let snippet = Snippet(triggers: [":x"],
                              variables: [Variable(name: "hang",
                                                   kind: .shell(command: "sleep 1",
                                                                timeoutSeconds: .infinity))])
        let group = SnippetGroup(name: "Broken", snippets: [snippet])

        #expect(throws: EncodingError.self) {
            try ConfigBundle.encode(groups: [group], globals: [], settings: .default)
        }
    }
}
