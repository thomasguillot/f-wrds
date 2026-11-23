import Foundation
import Testing
import WrdsKit

/// 2023-11-14 22:13:20 UTC. Every date expectation below is a literal, so the clock, the locale and
/// the time zone are all pinned.
private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
private let posix = Locale(identifier: "en_US_POSIX")

/// The marker the renderer leaves where a value could not be produced: U+26A0 followed by the text
/// variation selector U+FE0E. Spelled out here rather than read from the renderer, so that the
/// exact characters injected into the user's document are pinned by the tests.
private let warning = "⚠\u{FE0E}"

/// A mutable box for the `@Sendable` closures on `RenderContext`.
///
/// Safe by construction rather than by lock: `render` calls those closures inline, on the thread
/// that called it, and each test drives one render.
private final class Calls: @unchecked Sendable {
    private(set) var count = 0
    @discardableResult func record() -> Int {
        count += 1
        return count
    }
}

private func testContext(
    clipboard: @escaping @Sendable () -> String? = { nil },
    runShell: @escaping @Sendable (String, Double) throws -> String = { _, _ in
        Issue.record("the shell must not run for this snippet")
        return ""
    },
    pickRandom: @escaping @Sendable ([String]) -> String = { $0.first ?? "" },
    globals: [GlobalVariable] = [],
    regexCaptures: [String: String] = [:],
    formAnswers: [String: String] = [:]
) -> RenderContext {
    RenderContext(now: { fixedNow }, clipboard: clipboard, runShell: runShell,
                  pickRandom: pickRandom, globals: globals, regexCaptures: regexCaptures,
                  formAnswers: formAnswers, locale: posix, timeZone: .gmt)
}

private func snippet(_ content: String, _ variables: [Variable] = [],
                     uppercaseStyle: UppercaseStyle? = nil) -> Snippet {
    Snippet(triggers: [":t"], label: "Test", content: content,
            uppercaseStyle: uppercaseStyle, variables: variables)
}

private struct NotRendered: Error { let result: RenderResult }

private func expansion(_ snippet: Snippet, transform: CaseTransform = .none,
                       context: RenderContext = testContext()) throws -> RenderedExpansion {
    let result = ExpansionRenderer().render(snippet: snippet, transform: transform, context: context)
    guard case .rendered(let expansion) = result else { throw NotRendered(result: result) }
    return expansion
}

private func text(_ snippet: Snippet, transform: CaseTransform = .none,
                  context: RenderContext = testContext()) throws -> String {
    try expansion(snippet, transform: transform, context: context).text
}

@Suite("ExpansionRenderer")
struct ExpansionRendererTests {

    // MARK: Content without variables

    @Test("Content with no tokens renders unchanged")
    func rendersPlainContent() throws {
        #expect(try expansion(snippet("Hello, world.")) ==
            RenderedExpansion(text: "Hello, world.", cursorOffsetFromEnd: nil))
    }

    @Test("An unknown token is left in the text")
    func leavesUnknownTokensAlone() throws {
        // Recoverable, and visibly the author's typo. A ⚠︎ here would destroy the only clue as to
        // which variable was meant.
        #expect(try text(snippet("a {{nope}} b")) == "a {{nope}} b")
    }

    @Test("A context nobody wired anything into is still safe to render with")
    func hasSafeProductionDefaults() {
        // WrdsKit has no pasteboard and no subprocess of its own; the app layer injects both. Until
        // it does, the clipboard reads as empty and the shell fails visibly rather than quietly
        // rendering nothing where a command's output belonged.
        let out = Variable(name: "out", kind: .shell(command: "date", timeoutSeconds: 1))
        let pasted = Variable(name: "pasted", kind: .clipboard)
        let pick = Variable(name: "pick", kind: .choice(options: ["only"]))
        let content = snippet("[{{pasted}}][{{out}}][{{pick}}]", [out, pasted, pick])

        let result = ExpansionRenderer().render(snippet: content, transform: .none,
                                                context: RenderContext())

        #expect(result == .rendered(RenderedExpansion(text: "[][\(warning)][only]")))
    }

    // MARK: Date variables

    @Test("A date variable renders the clock through its format")
    func rendersDateVariable() throws {
        let today = Variable(name: "today", kind: .date(format: "%Y-%m-%d", offsetSeconds: 0))
        #expect(try text(snippet("Today is {{today}}", [today])) == "Today is 2023-11-14")
    }

    @Test("A date variable's offset shifts the date it renders")
    func offsetShiftsTheDate() throws {
        let tomorrow = Variable(name: "tomorrow", kind: .date(format: "%Y-%m-%d", offsetSeconds: 86_400))
        let yesterday = Variable(name: "yesterday",
                                 kind: .date(format: "%Y-%m-%d", offsetSeconds: -86_400))
        #expect(try text(snippet("{{yesterday}}..{{tomorrow}}", [tomorrow, yesterday]))
            == "2023-11-13..2023-11-15")
    }

    @Test("The clock is read once a render, and only if a date asks for it")
    func readsTheClockOnce() throws {
        // A snippet whose date and time are separate variables has to describe one moment, not two
        // readings that can fall either side of a second boundary.
        let calls = Calls()
        let day = Variable(name: "day", kind: .date(format: "%Y-%m-%d", offsetSeconds: 0))
        let time = Variable(name: "time", kind: .date(format: "%H:%M:%S", offsetSeconds: 0))
        let context = RenderContext(now: { calls.record(); return fixedNow },
                                    locale: posix, timeZone: .gmt)

        #expect(try text(snippet("{{day}} {{time}}", [day, time]), context: context)
            == "2023-11-14 22:13:20")
        #expect(calls.count == 1)

        #expect(try text(snippet("no dates here"), context: context) == "no dates here")
        #expect(calls.count == 1, "a snippet with no date variable never asks for the clock")
    }

    // MARK: Clipboard

    @Test("A clipboard variable substitutes what the clipboard holds")
    func rendersClipboard() throws {
        let pasted = Variable(name: "pasted", kind: .clipboard)
        let context = testContext(clipboard: { "from the clipboard" })
        #expect(try text(snippet(">{{pasted}}<", [pasted]), context: context)
            == ">from the clipboard<")
    }

    @Test("An empty clipboard substitutes nothing")
    func rendersEmptyClipboardAsNothing() throws {
        // Not a failure: pasting an empty clipboard is what the user asked for, and a ⚠︎ in the
        // middle of their sentence would be worse than a gap.
        let pasted = Variable(name: "pasted", kind: .clipboard)
        #expect(try text(snippet(">{{pasted}}<", [pasted])) == "><")
    }

    // MARK: Choice

    @Test("A choice variable picks through the context")
    func rendersChoice() throws {
        let pick = Variable(name: "pick", kind: .choice(options: ["one", "two", "three"]))
        // Returns the middle option only if all three arrived, so the assertion covers the hand-off
        // as well as the substitution.
        let context = testContext(pickRandom: { $0.count == 3 ? $0[1] : "wrong options" })
        #expect(try text(snippet("{{pick}}", [pick]), context: context) == "two")
    }

    @Test("A choice with nothing to choose from renders the warning")
    func rendersEmptyChoiceAsWarning() throws {
        let pick = Variable(name: "pick", kind: .choice(options: []))
        let context = testContext(pickRandom: { _ in
            Issue.record("an empty option list must not reach the picker")
            return ""
        })
        #expect(try text(snippet("[{{pick}}]", [pick]), context: context) == "[\(warning)]")
    }

    @Test("A variable is resolved once however often it is referenced")
    func resolvesEachVariableOnce() throws {
        // Two draws from one random variable in one expansion would read as a bug in the snippet.
        let calls = Calls()
        let pick = Variable(name: "pick", kind: .choice(options: ["a", "b"]))
        let context = testContext(pickRandom: { _ in "pick\(calls.record())" })
        #expect(try text(snippet("{{pick}}/{{pick}}", [pick]), context: context) == "pick1/pick1")
        #expect(calls.count == 1)
    }

    // MARK: Shell

    @Test("A shell variable substitutes the command's output")
    func rendersShellOutput() throws {
        let branch = Variable(name: "branch", kind: .shell(command: "git branch", timeoutSeconds: 2.5))
        // Echoes the arguments back so the assertion covers what was handed to the runner.
        let context = testContext(runShell: { command, timeout in "\(command)@\(timeout)" })
        #expect(try text(snippet("on {{branch}}", [branch]), context: context)
            == "on git branch@2.5")
    }

    @Test("A shell variable loses the newline the command ended with")
    func trimsTrailingNewlinesFromShellOutput() throws {
        // Nearly every command ends its output with a newline; pasting that into the middle of a
        // sentence would break the line. Leading whitespace is left alone — indentation can matter.
        let out = Variable(name: "out", kind: .shell(command: "echo hi", timeoutSeconds: 1))
        let context = testContext(runShell: { _, _ in "  hi\n\n" })
        #expect(try text(snippet("[{{out}}]", [out]), context: context) == "[  hi]")
    }

    @Test("A failing shell variable renders the warning and nothing else breaks")
    func rendersShellFailureAsWarning() throws {
        struct Boom: Error {}
        let out = Variable(name: "out", kind: .shell(command: "false", timeoutSeconds: 1))
        let context = testContext(runShell: { _, _ in throw Boom() })
        #expect(try text(snippet("before {{out}} after", [out]), context: context)
            == "before \(warning) after")
    }

    // MARK: Globals

    @Test("A global resolves by name")
    func rendersGlobalByName() throws {
        let global = GlobalVariable(variable: Variable(name: "signature", kind: .echo(value: "Thomas")))
        let context = testContext(globals: [global])
        #expect(try text(snippet("— {{signature}}"), context: context) == "— Thomas")
    }

    @Test("A local variable can point at a global")
    func rendersGlobalThroughLocalReference() throws {
        let global = GlobalVariable(variable: Variable(name: "signature", kind: .echo(value: "Thomas")))
        let local = Variable(name: "sig", kind: .global(name: "signature"))
        let context = testContext(globals: [global])
        #expect(try text(snippet("— {{sig}}", [local]), context: context) == "— Thomas")
    }

    @Test("A reference to a global that is not there renders the warning")
    func rendersMissingGlobalAsWarning() throws {
        let local = Variable(name: "sig", kind: .global(name: "gone"))
        #expect(try text(snippet("[{{sig}}]", [local])) == "[\(warning)]")
    }

    @Test("A global that points at another global renders the warning")
    func refusesToChainGlobals() throws {
        // Globals are values, not aliases. Chaining them is an invalid library rather than a cycle.
        let target = GlobalVariable(variable: Variable(name: "target", kind: .echo(value: "x")))
        let chained = GlobalVariable(variable: Variable(name: "chained", kind: .global(name: "target")))
        let context = testContext(globals: [chained, target])
        #expect(try text(snippet("[{{chained}}]"), context: context) == "[\(warning)]")
    }

    // MARK: Regex captures

    @Test("A regex capture substitutes by name")
    func rendersRegexCapture() throws {
        let context = testContext(regexCaptures: ["num": "42"])
        #expect(try text(snippet("note {{num}}"), context: context) == "note 42")
    }

    @Test("Snippet variables outrank globals, and globals outrank captures")
    func resolvesInPrecedenceOrder() throws {
        let local = Variable(name: "who", kind: .echo(value: "local"))
        let globalWho = GlobalVariable(variable: Variable(name: "who", kind: .echo(value: "global")))
        let globalWhere = GlobalVariable(variable: Variable(name: "place", kind: .echo(value: "global")))
        let context = testContext(globals: [globalWho, globalWhere],
                                  regexCaptures: ["who": "capture", "place": "capture"])

        #expect(try text(snippet("{{who}} {{place}}", [local]), context: context) == "local global")
        // With the local gone, the global takes over; with the global gone too, the capture does.
        #expect(try text(snippet("{{who}} {{place}}"), context: context) == "global global")
        #expect(try text(snippet("{{who}}"), context: testContext(regexCaptures: ["who": "capture"]))
            == "capture")
    }

    @Test("The first declaration of a duplicated name wins")
    func resolvesDuplicateNamesInDeclarationOrder() throws {
        let first = Variable(name: "dupe", kind: .echo(value: "first"))
        let second = Variable(name: "dupe", kind: .echo(value: "second"))
        #expect(try text(snippet("{{dupe}}", [first, second])) == "first")
    }

    // MARK: Dependencies and cycles

    @Test("A variable referenced by another resolves first, whatever the declaration order")
    func resolvesInDependencyOrder() throws {
        let greeting = Variable(name: "greeting", kind: .echo(value: "hello {{name}}"))
        let name = Variable(name: "name", kind: .echo(value: "world"))
        // `greeting` is declared before what it depends on, which is the case declaration order
        // alone would get wrong.
        #expect(try text(snippet("{{greeting}}!", [greeting, name])) == "hello world!")
    }

    @Test("A variable that references itself renders the warning")
    func rendersSelfCycleAsWarning() throws {
        let loop = Variable(name: "loop", kind: .echo(value: "[{{loop}}]"))
        #expect(try text(snippet("{{loop}}", [loop])) == "[\(warning)]")
    }

    @Test("A cycle warns at the token that closes it and the rest of the text survives")
    func rendersMutualCycleAsWarning() throws {
        let first = Variable(name: "first", kind: .echo(value: "<{{second}}>"))
        let second = Variable(name: "second", kind: .echo(value: "({{first}})"))
        #expect(try text(snippet("a {{first}} b", [first, second])) == "a <(\(warning))> b")
    }

    @Test("A cycle through a global is caught too")
    func rendersGlobalCycleAsWarning() throws {
        let global = GlobalVariable(variable: Variable(name: "loop", kind: .echo(value: "{{local}}")))
        let local = Variable(name: "local", kind: .echo(value: "{{loop}}"))
        let context = testContext(globals: [global])
        #expect(try text(snippet("[{{local}}]", [local]), context: context) == "[\(warning)]")
    }

    @Test("Only variable values are re-scanned for tokens, never runtime data")
    func doesNotExpandTokensArrivingFromOutside() throws {
        // A token in the clipboard, in shell output, or in a form answer is text the user copied,
        // not template the snippet author wrote. Expanding it would let outside data reach into the
        // snippet library.
        let secret = Variable(name: "secret", kind: .echo(value: "s3cret"))
        let pasted = Variable(name: "pasted", kind: .clipboard)
        let context = testContext(clipboard: { "{{secret}}" })
        #expect(try text(snippet("{{pasted}}", [secret, pasted]), context: context) == "{{secret}}")
    }

    // MARK: Cursor marker

    @Test("The cursor marker is stripped and its distance from the end recorded")
    func stripsCursorMarker() throws {
        #expect(try expansion(snippet("a$|$bc")) ==
            RenderedExpansion(text: "abc", cursorOffsetFromEnd: 2))
        #expect(try expansion(snippet("abc$|$")) ==
            RenderedExpansion(text: "abc", cursorOffsetFromEnd: 0))
        #expect(try expansion(snippet("$|$abc")) ==
            RenderedExpansion(text: "abc", cursorOffsetFromEnd: 3))
    }

    @Test("Only the first cursor marker is stripped")
    func stripsOnlyTheFirstCursorMarker() throws {
        // There is one caret. A second marker is an authoring mistake, and leaving it visible says
        // so more usefully than silently choosing one of the two.
        // The caret lands after the "a", which the surviving marker leaves five characters from
        // the end rather than two.
        #expect(try expansion(snippet("a$|$b$|$c")) ==
            RenderedExpansion(text: "ab$|$c", cursorOffsetFromEnd: 5))
    }

    @Test("The offset counts characters, not bytes or scalars")
    func countsTheOffsetInCharacters() throws {
        // "é" as e + combining accent, and a flag built from two regional indicators: three scalars
        // and eight UTF-8 bytes that the caret has to cross as two arrow presses.
        #expect(try expansion(snippet("x$|$e\u{301}🇫🇷")) ==
            RenderedExpansion(text: "xe\u{301}🇫🇷", cursorOffsetFromEnd: 2))
    }

    @Test("A marker produced by a variable still moves the cursor")
    func honoursAMarkerFromAVariableValue() throws {
        // Echo variables and globals are how a template gets factored out, so the marker has to
        // survive being one of them.
        let body = Variable(name: "body", kind: .echo(value: "Dear $|$,"))
        #expect(try expansion(snippet("{{body}}", [body])) ==
            RenderedExpansion(text: "Dear ,", cursorOffsetFromEnd: 1))
    }

    // MARK: Case transform

    @Test("No transform leaves the text as authored")
    func leavesTextAloneWithoutATransform() throws {
        #expect(try text(snippet("hello world")) == "hello world")
    }

    @Test("A capitalised match uppercases the first character")
    func appliesCapitalisedTransform() throws {
        #expect(try text(snippet("hello world"), transform: .capitalised) == "Hello world")
    }

    @Test("An uppercased match uppercases everything")
    func appliesUppercasedTransform() throws {
        #expect(try text(snippet("hello world"), transform: .uppercased) == "HELLO WORLD")
    }

    @Test("The transform applies to the substituted text, not the template")
    func appliesTransformAfterSubstitution() throws {
        let name = Variable(name: "name", kind: .echo(value: "thomas"))
        #expect(try text(snippet("{{name}} here", [name]), transform: .capitalised) == "Thomas here")
        #expect(try text(snippet("{{name}} here", [name]), transform: .uppercased) == "THOMAS HERE")
    }

    @Test("uppercaseStyle redirects a capitalised match")
    func honoursUppercaseStyle() throws {
        let words = snippet("hello wide world", uppercaseStyle: .capitaliseWords)
        let whole = snippet("hello wide world", uppercaseStyle: .uppercase)
        let first = snippet("hello wide world", uppercaseStyle: .capitalise)

        #expect(try text(words, transform: .capitalised) == "Hello Wide World")
        #expect(try text(whole, transform: .capitalised) == "HELLO WIDE WORLD")
        #expect(try text(first, transform: .capitalised) == "Hello wide world")
        // A match that was not cased at all is never transformed, whatever the style says.
        #expect(try text(words, transform: .none) == "hello wide world")
        #expect(try text(whole, transform: .none) == "hello wide world")
    }

    @Test("Words are split on whitespace only")
    func capitalisesWordsOnWhitespaceBoundaries() throws {
        let content = snippet("it's a well-known thing", uppercaseStyle: .capitaliseWords)
        #expect(try text(content, transform: .capitalised) == "It's A Well-known Thing")
    }

    @Test("A transform and a cursor marker do not disturb each other")
    func combinesTransformWithCursorMarker() throws {
        // The marker sits before the first letter, so capitalising has to look past it.
        #expect(try expansion(snippet("$|$hello"), transform: .capitalised) ==
            RenderedExpansion(text: "Hello", cursorOffsetFromEnd: 5))
        #expect(try expansion(snippet("ab$|$cd"), transform: .uppercased) ==
            RenderedExpansion(text: "ABCD", cursorOffsetFromEnd: 2))
        // Splitting a word with the marker must not start a new one.
        let words = snippet("he$|$llo world", uppercaseStyle: .capitaliseWords)
        #expect(try expansion(words, transform: .capitalised) ==
            RenderedExpansion(text: "Hello World", cursorOffsetFromEnd: 9))
    }

    // MARK: Forms

    private static let nameField = FormField(name: "name", label: "Name", kind: .text(default: ""))
    private static let toneField = FormField(name: "tone", label: "Tone",
                                             kind: .choice(options: ["warm", "curt"]))
    private static let sign = Variable(name: "sign", kind: .form(fields: [nameField, toneField]))

    @Test("A form with unanswered fields asks for them instead of rendering")
    func asksForAnUnansweredForm() {
        let result = ExpansionRenderer().render(snippet: snippet("Hi {{sign.name}}", [Self.sign]),
                                                transform: .none, context: testContext())
        #expect(result == .needsForm(variable: Self.sign, fields: [Self.nameField, Self.toneField]))
    }

    @Test("A partly answered form is still unanswered")
    func asksForAPartlyAnsweredForm() {
        let context = testContext(formAnswers: ["sign.name": "Tom"])
        let result = ExpansionRenderer().render(snippet: snippet("Hi {{sign.name}}", [Self.sign]),
                                                transform: .none, context: context)
        #expect(result == .needsForm(variable: Self.sign, fields: [Self.nameField, Self.toneField]))
    }

    @Test("An answered form substitutes its fields")
    func rendersAnsweredForm() throws {
        let context = testContext(formAnswers: ["sign.name": "Tom", "sign.tone": "warm"])
        #expect(try text(snippet("Hi {{sign.name}} ({{sign.tone}})", [Self.sign]), context: context)
            == "Hi Tom (warm)")
    }

    @Test("An answer left blank counts as answered")
    func treatsABlankAnswerAsGiven() throws {
        let context = testContext(formAnswers: ["sign.name": "", "sign.tone": "warm"])
        #expect(try text(snippet("Hi {{sign.name}}.", [Self.sign]), context: context) == "Hi .")
    }

    @Test("The first unanswered form is the one asked for")
    func asksForTheFirstUnansweredForm() {
        let second = Variable(name: "second", kind: .form(fields: [Self.nameField]))
        let content = snippet("{{sign.name}} {{second.name}}", [Self.sign, second])
        let context = testContext(formAnswers: ["sign.name": "Tom", "sign.tone": "warm"])
        let result = ExpansionRenderer().render(snippet: content, transform: .none, context: context)
        #expect(result == .needsForm(variable: second, fields: [Self.nameField]))
    }

    @Test("A form is asked for before anything is run or read")
    func asksForTheFormBeforeSideEffects() {
        // The expansion is about to pause for a panel. Running a command or draining the clipboard
        // now would happen once for the aborted render and again for the real one.
        let shellCalls = Calls()
        let clipboardCalls = Calls()
        let out = Variable(name: "out", kind: .shell(command: "date", timeoutSeconds: 1))
        let pasted = Variable(name: "pasted", kind: .clipboard)
        let context = testContext(clipboard: { clipboardCalls.record(); return "x" },
                                  runShell: { _, _ in "\(shellCalls.record())" })
        let content = snippet("{{out}} {{pasted}} {{sign.name}}", [out, pasted, Self.sign])

        let result = ExpansionRenderer().render(snippet: content, transform: .none, context: context)

        #expect(result == .needsForm(variable: Self.sign, fields: [Self.nameField, Self.toneField]))
        #expect(shellCalls.count == 0)
        #expect(clipboardCalls.count == 0)
    }

    @Test("A form reached through a global is asked for under the local name")
    func asksForAFormBehindAGlobal() throws {
        // The tokens say `{{sig.name}}`, so that — not the global's own name — is what the answers
        // are keyed under, at both ends of the round trip.
        let global = GlobalVariable(variable: Variable(name: "signature",
                                                       kind: .form(fields: [Self.nameField])))
        let local = Variable(name: "sig", kind: .global(name: "signature"))
        let content = snippet("Hi {{sig.name}}", [local])

        let unanswered = ExpansionRenderer().render(snippet: content, transform: .none,
                                                    context: testContext(globals: [global]))
        #expect(unanswered == .needsForm(variable: local, fields: [Self.nameField]))

        let answered = testContext(globals: [global], formAnswers: ["sig.name": "Tom"])
        #expect(try text(content, context: answered) == "Hi Tom")
    }

    @Test("A form variable referenced without a field renders the warning")
    func rendersBareFormTokenAsWarning() throws {
        // A form has no single value, so `{{sign}}` cannot mean anything. Says so where the author
        // will see it.
        let context = testContext(formAnswers: ["sign.name": "Tom", "sign.tone": "warm"])
        #expect(try text(snippet("[{{sign}}]", [Self.sign]), context: context) == "[\(warning)]")
    }

    @Test("A field the form never declared renders the warning")
    func rendersUnknownFormFieldAsWarning() throws {
        let context = testContext(formAnswers: ["sign.name": "Tom", "sign.tone": "warm"])
        #expect(try text(snippet("[{{sign.age}}]", [Self.sign]), context: context) == "[\(warning)]")
    }

    // MARK: Token syntax

    @Test("Spaces inside the braces are tolerated")
    func toleratesSpacesInsideBraces() throws {
        let name = Variable(name: "name", kind: .echo(value: "Thomas"))
        #expect(try text(snippet("{{ name }}", [name])) == "Thomas")
    }

    @Test("Braces that are not a token are left alone")
    func leavesNonTokenBracesAlone() throws {
        #expect(try text(snippet("{{}} {{ }} {{1bad}} {not a token}")) == "{{}} {{ }} {{1bad}} {not a token}")
    }
}
