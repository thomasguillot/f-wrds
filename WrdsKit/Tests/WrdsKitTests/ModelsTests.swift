import Foundation
import Testing
@testable import WrdsKit

private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
}

private func jsonObject(_ value: some Encodable) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    return object as? [String: Any] ?? [:]
}

@Suite("Models")
struct ModelsTests {

    // MARK: Snippet round-trip

    @Test("A fully populated snippet round-trips every field, including unmapped Espanso keys")
    func snippetRoundTripsEveryField() throws {
        let snippet = Snippet(
            triggers: [":sig", ";sig"],
            label: "Signature",
            content: "Best,\n{{name}}$|$",
            wordBoundary: true,
            propagateCase: true,
            uppercaseStyle: .capitaliseWords,
            variables: [Variable(name: "name", kind: .echo(value: "Thomas"))],
            isEnabled: false,
            unmapped: ["image_path": "~/shot.png", "html": "<b>hi</b>"]
        )

        let decoded = try roundTrip(snippet)

        #expect(decoded == snippet)
        #expect(decoded.id == snippet.id)
        #expect(decoded.triggers == [":sig", ";sig"])
        #expect(decoded.regexTrigger == nil)
        #expect(decoded.label == "Signature")
        #expect(decoded.content == "Best,\n{{name}}$|$")
        #expect(decoded.wordBoundary)
        #expect(decoded.propagateCase)
        #expect(decoded.uppercaseStyle == .capitaliseWords)
        #expect(decoded.variables == [Variable(id: snippet.variables[0].id, name: "name",
                                               kind: .echo(value: "Thomas"))])
        #expect(decoded.isEnabled == false)
        #expect(decoded.unmapped == ["image_path": "~/shot.png", "html": "<b>hi</b>"])
    }

    @Test("A regex-triggered snippet round-trips with its optionals set and unset")
    func snippetRoundTripsRegexTriggerAndDefaults() throws {
        let snippet = Snippet(regexTrigger: #":date(?<n>\d+)"#, label: "Dated")

        let decoded = try roundTrip(snippet)

        #expect(decoded == snippet)
        #expect(decoded.regexTrigger == #":date(?<n>\d+)"#)
        #expect(decoded.triggers.isEmpty)
        #expect(decoded.uppercaseStyle == nil)
        #expect(decoded.unmapped.isEmpty)
        #expect(decoded.isEnabled)
    }

    // MARK: Variable.Kind

    @Test("Variable.Kind decodes a date payload keyed by its type discriminator")
    func variableKindDecodesDiscriminatedDate() throws {
        let json = Data(#"{"type":"date","format":"%d","offsetSeconds":60}"#.utf8)

        let kind = try JSONDecoder().decode(Variable.Kind.self, from: json)

        #expect(kind == .date(format: "%d", offsetSeconds: 60))
    }

    @Test("Variable.Kind encodes a type discriminator alongside its payload")
    func variableKindEncodesDiscriminator() throws {
        let object = try jsonObject(Variable.Kind.date(format: "%Y", offsetSeconds: 0))

        #expect(object["type"] as? String == "date")
        #expect(object["format"] as? String == "%Y")
        #expect(object["offsetSeconds"] as? Int == 0)
    }

    @Test("Every Variable.Kind case round-trips", arguments: [
        Variable.Kind.date(format: "%Y-%m-%d", offsetSeconds: -3600),
        .clipboard,
        .choice(options: ["yes", "no"]),
        .echo(value: "hello"),
        .shell(command: "echo hi", timeoutSeconds: 1.5),
        .form(fields: [FormField(name: "email", label: "Email", kind: .text(default: ""))]),
        .global(name: "signature"),
    ])
    func variableKindRoundTrips(kind: Variable.Kind) throws {
        #expect(try roundTrip(kind) == kind)
    }

    @Test("Decoding an unknown Variable.Kind type throws")
    func variableKindRejectsUnknownType() {
        let json = Data(#"{"type":"telepathy","value":"x"}"#.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Variable.Kind.self, from: json)
        }
    }

    // MARK: FormField.Kind

    @Test("Every FormField.Kind case round-trips", arguments: [
        FormField.Kind.text(default: "Thomas"),
        .multiline(default: "line 1\nline 2"),
        .choice(options: ["small", "medium", "large"]),
    ])
    func formFieldKindRoundTrips(kind: FormField.Kind) throws {
        #expect(try roundTrip(kind) == kind)
    }

    @Test("FormField.Kind encodes a type discriminator alongside its payload")
    func formFieldKindEncodesDiscriminator() throws {
        let object = try jsonObject(FormField.Kind.text(default: "Thomas"))

        #expect(object["type"] as? String == "text")
        #expect(object["default"] as? String == "Thomas")
    }

    @Test("Decoding an unknown FormField.Kind type throws")
    func formFieldKindRejectsUnknownType() {
        let json = Data(#"{"type":"colourPicker","default":"red"}"#.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(FormField.Kind.self, from: json)
        }
    }

    // MARK: Containers

    @Test("A snippet group round-trips its app filters and snippets")
    func snippetGroupRoundTrips() throws {
        let group = SnippetGroup(
            name: "Work",
            snippets: [Snippet(triggers: [":wp"], content: "WordPress")],
            onlyInApps: ["com.apple.Safari"],
            neverInApps: ["com.apple.Terminal"],
            isEnabled: false
        )

        let decoded = try roundTrip(group)

        #expect(decoded == group)
        #expect(decoded.onlyInApps == ["com.apple.Safari"])
        #expect(decoded.neverInApps == ["com.apple.Terminal"])
        #expect(decoded.snippets.map(\.content) == ["WordPress"])
    }

    @Test("A global variable round-trips its wrapped variable")
    func globalVariableRoundTrips() throws {
        let global = GlobalVariable(variable: Variable(name: "greeting", kind: .echo(value: "Hi")))

        let decoded = try roundTrip(global)

        #expect(decoded == global)
        #expect(decoded.variable.name == "greeting")
        #expect(decoded.variable.kind == .echo(value: "Hi"))
    }

    @Test("UppercaseStyle exposes every case with a stable raw value")
    func uppercaseStyleRawValues() {
        #expect(UppercaseStyle.allCases == [.capitalise, .capitaliseWords, .uppercase])
        #expect(UppercaseStyle.allCases.map(\.rawValue) == ["capitalise", "capitaliseWords", "uppercase"])
    }

    // MARK: Shell timeout clamping
    //
    // `store.json` is not a trusted input: a hand edit, a merge or a restored backup can put
    // anything in `timeoutSeconds`, and `ShellRunner` reads a big enough number as "no deadline at
    // all" — on the one serial queue every expansion and every keystroke behind it is confined to.
    // One such variable would wedge expansion permanently, with nothing to say so.

    @Test("A shell timeout beyond the ceiling decodes clamped to it")
    func shellTimeoutClampsToCeiling() throws {
        #expect(try decodedShellTimeout("1e10") == 3600)
        #expect(try decodedShellTimeout("3601") == 3600)
    }

    @Test("A shell timeout that says nothing usable decodes as the default")
    func shellTimeoutFallsBackForUnusableValues() throws {
        #expect(try decodedShellTimeout("-5") == 10)
        #expect(try decodedShellTimeout("0") == 10)
    }

    @Test("An ordinary shell timeout decodes unchanged")
    func shellTimeoutPassesThroughInRange() throws {
        #expect(try decodedShellTimeout("1.5") == 1.5)
        #expect(try decodedShellTimeout("3600") == 3600)
    }

    /// `NaN` and infinity are guarded at the same door, and tested against the clamp directly rather
    /// than through a file: JSON has no spelling for either, and a literal big enough to overflow a
    /// `Double` makes `JSONDecoder` reject the whole document before this code is reached. The guard
    /// stays because the clamp is the model's answer to "this number is not a duration", and a
    /// second caller — or a second decoder — should not have to rediscover that.
    @Test("Non-finite timeouts fall back rather than clamping")
    func shellTimeoutRejectsNonFiniteValues() {
        #expect(Variable.Kind.clampedShellTimeout(.nan) == 10)
        #expect(Variable.Kind.clampedShellTimeout(.infinity) == 10)
        #expect(Variable.Kind.clampedShellTimeout(-.infinity) == 10)
    }

    /// The timeout a `.shell` variable comes back with, decoded from JSON written by hand so the
    /// value under test is one no encoder of this app's would produce.
    private func decodedShellTimeout(_ literal: String) throws -> Double {
        let json = """
            {"type":"shell","command":"echo hi","timeoutSeconds":\(literal)}
            """
        let kind = try JSONDecoder().decode(Variable.Kind.self, from: Data(json.utf8))
        guard case .shell(_, let timeoutSeconds) = kind else {
            Issue.record("expected a shell variable, got \(kind)")
            return .nan
        }
        return timeoutSeconds
    }
}
