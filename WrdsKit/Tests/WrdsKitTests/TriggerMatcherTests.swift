import Foundation
import Testing
import WrdsKit

/// Feeds `text` into `matcher` one character at a time, collecting every match that fired.
///
/// Keystroke-at-a-time is the only way the matcher is ever driven in production, so the tests
/// drive it the same way rather than handing it whole strings.
private func matches(_ text: String, into matcher: TriggerMatcher) -> [TriggerMatch] {
    text.compactMap { matcher.process(.character($0)) }
}

/// Feeds `text` into `matcher` one character at a time, returning the last match that fired.
@discardableResult
private func type(_ text: String, into matcher: TriggerMatcher) -> TriggerMatch? {
    matches(text, into: matcher).last
}

@Suite("TriggerMatcher")
struct TriggerMatcherTests {

    private static let sig = Snippet(triggers: [":sig"], label: "Signature", content: "Thomas")
    private static let email = Snippet(triggers: [":email"], label: "Email", content: "thomas@a8c.com")
    /// A word-boundary trigger whose letters also sit inside ordinary words ("per*so*n").
    private static let somewhere = Snippet(triggers: ["so"], label: "Somewhere", content: "somewhere",
                                           wordBoundary: true)
    private static let propagatingSig = Snippet(triggers: [":sig"], label: "Signature",
                                                content: "thomas", propagateCase: true)
    /// Two digits rather than `\d+`: an open-ended quantifier fires on the first digit, so it could
    /// never demonstrate a multi-character capture. See `regexMatchingIsEager`.
    private static let twoDigitNote = Snippet(regexTrigger: #"//(?<num>\d{2})"#, label: "Note",
                                              content: "note {{num}}")

    // MARK: Plain matching

    @Test("A plain trigger matches on the keystroke that completes it")
    func matchesPlainTrigger() throws {
        let matcher = TriggerMatcher()
        matcher.setSnippets([Self.sig])

        #expect(type(":si", into: matcher) == nil, "an incomplete trigger must not fire")
        let match = try #require(matcher.process(.character("g")))

        #expect(match == TriggerMatch(snippetID: Self.sig.id, typedText: ":sig",
                                      caseTransform: .none, regexCaptures: [:]))
    }

    @Test("Every trigger on a snippet matches it")
    func matchesAnyOfASnippetsTriggers() {
        // Neither trigger may be a prefix of the other: matching is eager, so ":sig" alongside
        // ":signature" would fire on the "g" and pass whether or not ":signature" was registered
        // at all. Asserting `typedText` is what decides *which* trigger fired.
        let snippet = Snippet(triggers: [":sig", ":email"], content: "Thomas")
        let matcher = TriggerMatcher()
        matcher.setSnippets([snippet])

        #expect(type(":sig", into: matcher) == TriggerMatch(snippetID: snippet.id, typedText: ":sig"))
        #expect(type(":email", into: matcher) == TriggerMatch(snippetID: snippet.id, typedText: ":email"))
    }

    @Test("Matching is case-sensitive")
    func matchingIsCaseSensitive() {
        let matcher = TriggerMatcher()
        matcher.setSnippets([Self.sig])

        #expect(type(":Sig", into: matcher) == nil)
    }

    @Test("An empty trigger never fires")
    func emptyTriggerNeverFires() {
        // An empty trigger would otherwise sit at the root of the trie and match every keystroke.
        let empty = Snippet(triggers: [""], label: "Empty", content: "boom")
        let matcher = TriggerMatcher()
        matcher.setSnippets([empty, Self.sig])

        #expect(matches("hello :sig", into: matcher).map(\.snippetID) == [Self.sig.id])
    }

    @Test("A snippet with a regex trigger takes no part in plain matching")
    func regexSnippetsAreIgnored() {
        // Deliberately malformed — the model says triggers are empty when a regex is set — so the
        // matcher's own skip is what is under test, not the model invariant. ":num" alone does not
        // satisfy the regex either, so nothing may fire down either path.
        let regexSnippet = Snippet(triggers: [":num"], regexTrigger: #":num\d+"#, content: "…")
        let matcher = TriggerMatcher()
        matcher.setSnippets([regexSnippet])

        #expect(type(":num", into: matcher) == nil)
    }

    @Test("setSnippets replaces the previous set rather than adding to it")
    func setSnippetsReplaces() {
        let matcher = TriggerMatcher()
        matcher.setSnippets([Self.sig])
        matcher.setSnippets([Self.email])

        #expect(type(":sig", into: matcher) == nil)
        #expect(type(":email", into: matcher)?.snippetID == Self.email.id)
    }

    @Test("setSnippets leaves a half-typed trigger in the buffer")
    func setSnippetsPreservesTheBuffer() {
        // The library changing mid-word does not change what is on screen in front of the caret,
        // so an edit saved between two keystrokes must not swallow the trigger being typed.
        let matcher = TriggerMatcher()
        matcher.setSnippets([Self.sig])

        type(":si", into: matcher)
        matcher.setSnippets([Self.sig, Self.email])

        #expect(matcher.process(.character("g"))?.snippetID == Self.sig.id)
    }

    // MARK: Precedence

    @Test("The longest trigger wins when several complete on the same keystroke")
    func longestTriggerWins() throws {
        // Both triggers end on the final "l" of ":email". (A trigger that is a *prefix* of another,
        // such as ":e", cannot be tested this way: matching is eager, so ":e" fires on its own "e"
        // long before ":email" could complete.)
        let mail = Snippet(triggers: ["mail"], content: "mail")
        let matcher = TriggerMatcher()
        matcher.setSnippets([mail, Self.email])

        let match = try #require(type(":email", into: matcher))

        #expect(match.snippetID == Self.email.id)
        #expect(match.typedText == ":email")
    }

    @Test("Among equal-length triggers the first snippet given to setSnippets wins")
    func firstSnippetWinsOnEqualLength() {
        let first = Snippet(triggers: [":sig"], content: "first")
        let second = Snippet(triggers: [":sig"], content: "second")

        let inOrder = TriggerMatcher()
        inOrder.setSnippets([first, second])
        #expect(type(":sig", into: inOrder)?.snippetID == first.id)

        // Reversed, to prove the winner follows the given order rather than anything about the IDs.
        let reversed = TriggerMatcher()
        reversed.setSnippets([second, first])
        #expect(type(":sig", into: reversed)?.snippetID == second.id)
    }

    // MARK: Word boundaries

    @Test("A word-boundary trigger does not fire inside a word")
    func wordBoundaryTriggerDoesNotFireMidWord() {
        let matcher = TriggerMatcher()
        matcher.setSnippets([Self.somewhere])

        #expect(type("person", into: matcher) == nil)
    }

    @Test("A word-boundary trigger fires at the buffer start and after a delimiter")
    func wordBoundaryTriggerFiresAfterADelimiter() {
        let matcher = TriggerMatcher()
        matcher.setSnippets([Self.somewhere])

        // ":" earns its place in the sample twice over: it is a delimiter, and it is the first
        // character of every house-style trigger.
        for lead in ["", "hello ", "wait(", "done.", "note:", "he said \"", "tab\t", "line\n"] {
            matcher.resetBuffer()
            #expect(type(lead + "so", into: matcher)?.snippetID == Self.somewhere.id,
                    "expected a match after \(String(reflecting: lead))")
        }
    }

    @Test("A word-boundary trigger yields to a plain snippet sharing the same trigger")
    func plainSnippetMatchesWhereWordBoundaryOneCannot() {
        let plain = Snippet(triggers: ["so"], content: "plain")
        let matcher = TriggerMatcher()
        matcher.setSnippets([Self.somewhere, plain])

        // Mid-word the boundary snippet is out, so the plain one — listed second — takes it.
        #expect(type("person", into: matcher)?.snippetID == plain.id)
        // At a boundary the first eligible snippet still wins.
        #expect(type(" so", into: matcher)?.snippetID == Self.somewhere.id)
    }

    @Test("A shorter trigger fires when the longer one is blocked by its word boundary")
    func shorterTriggerFiresWhenLongerIsBlocked() {
        let bounded = Snippet(triggers: ["email"], content: "bounded", wordBoundary: true)
        let mail = Snippet(triggers: ["mail"], content: "mail")
        let matcher = TriggerMatcher()
        matcher.setSnippets([bounded, mail])

        // "xemail": "email" is blocked by the preceding "x", so the shorter "mail" wins.
        #expect(type("xemail", into: matcher)?.snippetID == mail.id)
    }

    // MARK: Case propagation

    @Test("A propagating trigger typed as authored reports no transform")
    func propagatingTriggerTypedAsAuthored() {
        let matcher = TriggerMatcher()
        matcher.setSnippets([Self.propagatingSig])

        #expect(type(":sig", into: matcher)
                == TriggerMatch(snippetID: Self.propagatingSig.id, typedText: ":sig", caseTransform: .none))
    }

    @Test("A propagating trigger typed with its first letter uppercased is capitalised")
    func propagatingTriggerCapitalised() {
        let matcher = TriggerMatcher()
        matcher.setSnippets([Self.propagatingSig])

        // `typedText` is what the caller deletes, so it has to be the casing actually typed rather
        // than the trigger as authored.
        #expect(type(":Sig", into: matcher)
                == TriggerMatch(snippetID: Self.propagatingSig.id, typedText: ":Sig",
                                caseTransform: .capitalised))
    }

    @Test("A propagating trigger typed in full uppercase is uppercased")
    func propagatingTriggerUppercased() {
        let matcher = TriggerMatcher()
        matcher.setSnippets([Self.propagatingSig])

        #expect(type(":SIG", into: matcher)
                == TriggerMatch(snippetID: Self.propagatingSig.id, typedText: ":SIG",
                                caseTransform: .uppercased))
    }

    @Test("A case mixture that is neither capitalised nor uppercased does not match")
    func propagatingTriggerRejectsOtherMixtures() {
        let matcher = TriggerMatcher()
        matcher.setSnippets([Self.propagatingSig])

        // Propagating case is not the same as matching case-insensitively: only the two casings a
        // person types on purpose carry a meaning the expansion can be rendered in.
        for typed in [":sIg", ":sIG", ":siG"] {
            matcher.resetBuffer()
            #expect(type(typed, into: matcher) == nil, "expected no match for \(typed)")
        }
    }

    @Test("A single-letter trigger typed uppercase is capitalised, not uppercased")
    func singleLetterTriggerUppercaseIsCapitalised() {
        // ":S" is equally readable as a shout or a capitalisation; capitalising is the one that
        // leaves a one-word expansion looking like prose.
        let short = Snippet(triggers: [":s"], content: "Thomas", propagateCase: true)
        let matcher = TriggerMatcher()
        matcher.setSnippets([short])

        #expect(type(":S", into: matcher)
                == TriggerMatch(snippetID: short.id, typedText: ":S", caseTransform: .capitalised))
    }

    @Test("Case folding one trigger does not loosen another in the same matcher")
    func caseFoldingIsPerTrigger() {
        // The trie is keyed case-folded so a keystroke still costs one walk; the entry decides
        // whether the casing typed is acceptable. A non-propagating neighbour must stay exact.
        let matcher = TriggerMatcher()
        matcher.setSnippets([Self.propagatingSig, Self.email])

        #expect(type(":Email", into: matcher) == nil)
        #expect(type(":EMAIL", into: matcher) == nil)
        #expect(type(":Sig", into: matcher)?.caseTransform == .capitalised)
    }

    @Test("A propagating trigger still respects its word boundary")
    func propagatingTriggerRespectsWordBoundary() {
        let bounded = Snippet(triggers: ["so"], content: "somewhere", wordBoundary: true,
                              propagateCase: true)
        let matcher = TriggerMatcher()
        matcher.setSnippets([bounded])

        #expect(type("perSo", into: matcher) == nil)
        matcher.resetBuffer()
        #expect(type(" So", into: matcher)
                == TriggerMatch(snippetID: bounded.id, typedText: "So", caseTransform: .capitalised))
    }

    // MARK: Regex triggers

    @Test("A regex trigger fires with its named captures")
    func regexTriggerFiresWithNamedCaptures() {
        let matcher = TriggerMatcher()
        matcher.setSnippets([Self.twoDigitNote])

        #expect(type("//42", into: matcher)
                == TriggerMatch(snippetID: Self.twoDigitNote.id, typedText: "//42",
                                caseTransform: .none, regexCaptures: ["num": "42"]))
    }

    @Test("A regex trigger ignores the text in front of it")
    func regexTriggerIgnoresTextBeforeIt() {
        let matcher = TriggerMatcher()
        matcher.setSnippets([Self.twoDigitNote])

        // The regex sees the whole buffer, and `typedText` is only the part the caller deletes.
        #expect(type("see //42", into: matcher)?.typedText == "//42")
    }

    @Test("A regex trigger never fires on a match stranded behind the caret")
    func regexNeverFiresOnAMatchBehindTheCaret() {
        // The one test that pins the end anchor, and the reason the anchor exists at all. A match
        // that stops short of the caret is not a missed expansion, it is text corruption:
        // `typedText` is a suffix the caller deletes, so firing "42" inside "ab42x" would delete the
        // "2x" the user just typed and expand over it.
        //
        // Getting a stale match to sit there takes the buffer surviving `setSnippets` — deliberate,
        // and tested above. Registered from the start, the regex would have fired on the "2" and
        // emptied the buffer long before the "x" arrived.
        let digits = Snippet(regexTrigger: #"(?<num>\d{2})"#, content: "digits")
        let matcher = TriggerMatcher()
        matcher.setSnippets([])

        type("ab42", into: matcher)
        matcher.setSnippets([digits])

        #expect(matcher.process(.character("x")) == nil)
    }

    @Test("A regex trigger fires as eagerly as a plain one")
    func regexMatchingIsEager() {
        // Same lesson as a trigger that is a prefix of another: the matcher cannot know what comes
        // next, so an open-ended quantifier fires on the first keystroke that satisfies it. `\d+`
        // therefore matches "//4", never "//42" — which is why the capture test uses `\d{2}`.
        let openEnded = Snippet(regexTrigger: #"//(?<num>\d+)"#, content: "note")
        let matcher = TriggerMatcher()
        matcher.setSnippets([openEnded])

        #expect(matches("//42", into: matcher)
                == [TriggerMatch(snippetID: openEnded.id, typedText: "//4", caseTransform: .none,
                                 regexCaptures: ["num": "4"])])
    }

    @Test("A regex match empties the buffer, so the text after it cannot re-trigger")
    func regexMatchEmptiesTheBuffer() throws {
        let matcher = TriggerMatcher()
        matcher.setSnippets([Self.twoDigitNote])

        #expect(type("//4", into: matcher) == nil, "one digit is not yet the trigger")
        let match = try #require(matcher.process(.character("2")), "the second digit completes it")
        #expect(match.typedText == "//42")
        // "//42" has been consumed, so the "x" lands in an empty buffer with nothing to extend.
        #expect(matcher.process(.character("x")) == nil)
    }

    @Test("A plain trigger wins over a regex that completes on the same keystroke")
    func plainTriggerWinsOverRegex() throws {
        // Regex is the fallback, evaluated only once the trie walk has come up empty — both so the
        // common keystroke never pays for it, and so precedence is something a library author can
        // predict.
        let regexSnippet = Snippet(regexTrigger: #":si(?<last>g)"#, content: "regex")
        let matcher = TriggerMatcher()
        matcher.setSnippets([regexSnippet, Self.sig])

        let match = try #require(type(":sig", into: matcher))

        #expect(match.snippetID == Self.sig.id)
        #expect(match.regexCaptures.isEmpty)
    }

    @Test("Among regex triggers the first snippet given to setSnippets wins")
    func firstRegexSnippetWins() {
        let first = Snippet(regexTrigger: #"//(?<num>\d{2})"#, content: "first")
        let second = Snippet(regexTrigger: #"/(?<num>\d{2})"#, content: "second")

        // Asserting `typedText` too: the two patterns cover different spans of the same buffer, so
        // the winner decides how much the caller deletes, not just what it expands.
        let inOrder = TriggerMatcher()
        inOrder.setSnippets([first, second])
        #expect(type("//42", into: inOrder)
                == TriggerMatch(snippetID: first.id, typedText: "//42", regexCaptures: ["num": "42"]))

        let reversed = TriggerMatcher()
        reversed.setSnippets([second, first])
        #expect(type("//42", into: reversed)
                == TriggerMatch(snippetID: second.id, typedText: "/42", regexCaptures: ["num": "42"]))
    }

    @Test("A regex trigger respects its word boundary")
    func regexTriggerRespectsWordBoundary() {
        let bounded = Snippet(regexTrigger: #"(?<num>\d{2})"#, content: "bounded", wordBoundary: true)
        let matcher = TriggerMatcher()
        matcher.setSnippets([bounded])

        #expect(type("x42", into: matcher) == nil)
        matcher.resetBuffer()
        #expect(type(" 42", into: matcher)?.typedText == "42")
    }

    @Test("An invalid regex pattern is skipped instead of crashing")
    func invalidRegexPatternIsSkipped() {
        // The editor validates patterns before they are saved; the matcher runs inside the event
        // tap, where refusing to load the rest of the library would be far worse than one dead rule.
        let invalid = Snippet(regexTrigger: "[unclosed", content: "boom")
        let matcher = TriggerMatcher()
        matcher.setSnippets([invalid, Self.twoDigitNote])

        #expect(type("//42", into: matcher)?.snippetID == Self.twoDigitNote.id)
    }

    @Test("A regex that can match nothing never fires")
    func regexMatchingNothingNeverFires() {
        // Both patterns match the empty string at the end of every buffer. Firing on that would
        // expand on every keystroke with nothing to delete — and, because a match empties the
        // buffer, it would also stop every other trigger from ever completing.
        for pattern in ["", #"\d*"#] {
            let hungry = Snippet(regexTrigger: pattern, content: "boom")
            let matcher = TriggerMatcher()
            matcher.setSnippets([hungry, Self.sig])

            #expect(matches("hello :sig", into: matcher).map(\.snippetID) == [Self.sig.id],
                    "expected only :sig to fire alongside \(String(reflecting: pattern))")
        }
    }

    @Test("setSnippets replaces regex triggers as well as plain ones")
    func setSnippetsReplacesRegexTriggers() {
        let matcher = TriggerMatcher()
        matcher.setSnippets([Self.twoDigitNote])
        matcher.setSnippets([Self.sig])

        #expect(type("//42", into: matcher) == nil)
    }

    // MARK: Buffer editing

    @Test("A seeded character answers the word-boundary test for what is typed next")
    func seedAnswersWordBoundary() {
        let matcher = TriggerMatcher()
        matcher.setSnippets([Self.somewhere])

        matcher.resetBuffer(seededWith: "r")
        #expect(type("so", into: matcher) == nil)

        matcher.resetBuffer(seededWith: " ")
        #expect(type("so", into: matcher)?.snippetID == Self.somewhere.id)
    }

    @Test("A seeded character stays in the buffer even when it is a whole trigger")
    func seedNeverMatchesOnItsOwn() throws {
        let single = Snippet(triggers: ["m"], label: "M", content: "M")
        let matcher = TriggerMatcher()
        matcher.setSnippets([single, Self.somewhere])

        matcher.resetBuffer(seededWith: "m")
        #expect(type("so", into: matcher) == nil)

        matcher.resetBuffer(seededWith: "m")
        let typed = try #require(type("m", into: matcher))
        #expect(typed.typedText == "m")
    }

    @Test("A trigger cannot reach back over a seeded character")
    func triggerCannotReachOverSeed() {
        let matcher = TriggerMatcher()
        matcher.setSnippets([Self.sig])

        matcher.resetBuffer(seededWith: ":")
        #expect(type("sig", into: matcher) == nil)
    }

    @Test("The longest trigger made only of typed characters wins over one that needs the seed")
    func shorterTypedTriggerWinsOverSeededOne() throws {
        let dotSig = Snippet(triggers: [".sig"], content: "dot")
        let plainSig = Snippet(triggers: ["sig"], content: "plain")
        let matcher = TriggerMatcher()
        matcher.setSnippets([dotSig, plainSig])

        matcher.resetBuffer(seededWith: ".")
        let match = try #require(type("sig", into: matcher))
        #expect(match == TriggerMatch(snippetID: plainSig.id, typedText: "sig"))
    }

    @Test("A regex trigger after a seed matches only the typed characters")
    func regexAfterSeedMatchesTypedOnly() throws {
        let word = Snippet(regexTrigger: "(?<word>[a-z]+);;", content: "{{word}}")
        let matcher = TriggerMatcher()
        matcher.setSnippets([word])

        for seed: Character in ["m", "\u{1F44D}\u{1F3FD}"] {
            matcher.resetBuffer(seededWith: seed)
            let match = try #require(type("ab;;", into: matcher))
            #expect(match.typedText == "ab;;")
            #expect(match.regexCaptures == ["word": "ab"])
        }
    }

    @Test("A word-boundary regex trigger reads the seed as what precedes it")
    func wordBoundaryRegexReadsSeed() {
        let word = Snippet(regexTrigger: "[a-z]+;;", content: "x", wordBoundary: true)
        let matcher = TriggerMatcher()
        matcher.setSnippets([word])

        matcher.resetBuffer(seededWith: "m")
        #expect(type("ab;;", into: matcher) == nil)

        matcher.resetBuffer(seededWith: " ")
        #expect(type("ab;;", into: matcher)?.snippetID == word.id)
    }

    @Test("A propagating trigger after a seed reads its casing from the typed characters")
    func casePropagationAfterSeed() throws {
        let matcher = TriggerMatcher()
        matcher.setSnippets([Self.propagatingSig])

        matcher.resetBuffer(seededWith: "A")
        let match = try #require(type(":SIG", into: matcher))
        #expect(match.typedText == ":SIG")
        #expect(match.caseTransform == .uppercased)
    }

    @Test("A seed stops counting once it rolls off the front of the buffer")
    func seedRollsOff() {
        let exactFit = Snippet(triggers: ["1234"], content: "fits")
        let matcher = TriggerMatcher(maxBufferLength: 4)
        matcher.setSnippets([exactFit])

        matcher.resetBuffer(seededWith: "x")
        #expect(type("1234", into: matcher) == TriggerMatch(snippetID: exactFit.id, typedText: "1234"))
    }

    @Test("Backspacing over the seed leaves an empty buffer; backspacing typing keeps the seed")
    func backspaceAndSeed() {
        let matcher = TriggerMatcher()
        matcher.setSnippets([Self.somewhere])

        matcher.resetBuffer(seededWith: "r")
        type("x", into: matcher)
        _ = matcher.process(.backspace)
        #expect(type("so", into: matcher) == nil)

        matcher.resetBuffer(seededWith: "r")
        _ = matcher.process(.backspace)
        #expect(type("so", into: matcher)?.snippetID == Self.somewhere.id)
    }

    @Test("Backspace un-does a keystroke, so the partial trigger no longer completes")
    func backspaceUndoesProgress() {
        let matcher = TriggerMatcher()
        matcher.setSnippets([Self.sig])

        type(":si", into: matcher)
        #expect(matcher.process(.backspace) == nil)

        // The buffer is ":s", so "g" makes ":sg" — not a trigger.
        #expect(matcher.process(.character("g")) == nil)
    }

    @Test("A trigger still completes after a backspace correction")
    func triggerCompletesAfterBackspaceCorrection() throws {
        let matcher = TriggerMatcher()
        matcher.setSnippets([Self.sig])

        type(":si", into: matcher)
        #expect(matcher.process(.backspace) == nil)

        // Retyping leaves the buffer at ":sig", exactly as if the correction had never happened.
        #expect(matcher.process(.character("i")) == nil)
        let match = try #require(matcher.process(.character("g")))
        #expect(match.typedText == ":sig")
    }

    @Test("Backspace on an empty buffer is harmless")
    func backspaceOnEmptyBufferIsHarmless() {
        let matcher = TriggerMatcher()
        matcher.setSnippets([Self.sig])

        #expect(matcher.process(.backspace) == nil)
        #expect(type(":sig", into: matcher)?.snippetID == Self.sig.id)
    }

    @Test("A reset input empties the buffer")
    func resetInputEmptiesTheBuffer() {
        let matcher = TriggerMatcher()
        matcher.setSnippets([Self.sig])

        type(":si", into: matcher)
        #expect(matcher.process(.reset) == nil)

        #expect(matcher.process(.character("g")) == nil)
        #expect(type(":sig", into: matcher)?.snippetID == Self.sig.id, "resetting must not disable matching")
    }

    @Test("resetBuffer() empties the buffer")
    func resetBufferEmptiesTheBuffer() {
        let matcher = TriggerMatcher()
        matcher.setSnippets([Self.sig])

        type(":si", into: matcher)
        matcher.resetBuffer()

        #expect(matcher.process(.character("g")) == nil)
    }

    @Test("A match empties the buffer, so overlapping text cannot re-trigger")
    func matchEmptiesTheBuffer() {
        let doubled = Snippet(triggers: ["aa"], content: "doubled")
        let matcher = TriggerMatcher()
        matcher.setSnippets([doubled])

        // Without clearing, the third "a" would fire a second, overlapping match.
        #expect(matches("aaa", into: matcher).count == 1)
    }

    @Test("The same trigger typed twice in a row fires twice")
    func consecutiveTriggersBothFire() {
        let matcher = TriggerMatcher()
        matcher.setSnippets([Self.sig])

        #expect(matches(":sig:sig", into: matcher).map(\.snippetID) == [Self.sig.id, Self.sig.id])
    }

    // MARK: Buffer length

    @Test("A trigger matches after more characters than the buffer holds have been typed")
    func matchesAfterTheBufferHasRolledOver() {
        let matcher = TriggerMatcher()
        matcher.setSnippets([Self.sig])

        #expect(type(String(repeating: "a", count: 65), into: matcher) == nil)
        #expect(type(":sig", into: matcher)?.snippetID == Self.sig.id)
    }

    @Test("A trigger the length of the buffer matches; one character longer never can")
    func bufferLengthBoundsTriggerLength() {
        // The buffer bounds how far back the matcher can see, so it also bounds trigger length —
        // pinned from both sides, since the exact-fit case is the one a rounding error would break.
        // Separate matchers: registered together, "1234" would fire before "12345" could complete.
        let exactFit = Snippet(triggers: ["1234"], content: "exactly the buffer length")
        let tooLong = Snippet(triggers: ["12345"], content: "one character too long")

        let fits = TriggerMatcher(maxBufferLength: 4)
        fits.setSnippets([exactFit])
        #expect(type("x1234", into: fits) == TriggerMatch(snippetID: exactFit.id, typedText: "1234"))

        // The leading "1" has been trimmed away by the time "5" arrives, so the walk backwards can
        // never reach the start of the trigger.
        let doesNotFit = TriggerMatcher(maxBufferLength: 4)
        doesNotFit.setSnippets([tooLong])
        #expect(type("x12345", into: doesNotFit) == nil)
    }

    @Test("A buffer length below one is clamped instead of trapping on the first keystroke")
    func buffersShorterThanOneAreClamped() {
        // Nonsense to ask for, but this runs inside the event tap: trimming to a negative length
        // would trap on the user's next keystroke rather than fail anywhere it could be noticed.
        let single = Snippet(triggers: ["a"], content: "one character")
        let matcher = TriggerMatcher(maxBufferLength: 0)
        matcher.setSnippets([single])

        #expect(type("a", into: matcher)?.snippetID == single.id)
    }
}
