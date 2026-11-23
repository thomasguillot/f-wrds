import Foundation

/// One keystroke, as the matcher sees it.
///
/// The event tap does the interpreting: anything that moves the caret or changes context — arrows,
/// return, escape, a modifier combination, a mouse click, an app switch — arrives as `.reset`,
/// because the characters before it are no longer adjacent to what the user types next.
public enum KeyInput: Equatable, Sendable {
    case character(Character)
    case backspace
    case reset
}

/// How the casing the user typed should be carried onto the expansion.
public enum CaseTransform: Equatable, Sendable {
    case none
    case capitalised
    case uppercased
}

/// A trigger that fired, and everything the caller needs to replace it.
public struct TriggerMatch: Equatable, Sendable {
    public let snippetID: UUID
    /// Exactly the characters the user typed for this trigger — the caller deletes this many.
    public let typedText: String
    public let caseTransform: CaseTransform
    /// Named captures from a regex trigger. Always empty for a plain trigger.
    public let regexCaptures: [String: String]

    public init(snippetID: UUID, typedText: String, caseTransform: CaseTransform = .none,
                regexCaptures: [String: String] = [:]) {
        self.snippetID = snippetID
        self.typedText = typedText
        self.caseTransform = caseTransform
        self.regexCaptures = regexCaptures
    }
}

/// Turns a stream of keystrokes into trigger matches.
///
/// Every keystroke the user makes anywhere in the OS passes through `process(_:)`, so the cost per
/// keystroke has to be independent of how many snippets exist. Triggers are therefore stored
/// reversed in a prefix trie: a keystroke walks backwards from the end of the buffer, one node per
/// character, and stops as soon as the path runs out. The work is bounded by the longest trigger
/// that shares a suffix with what was just typed, never by the number of plain triggers. Regex
/// triggers are the exception to that, and are the paragraph after next.
///
/// Matching is eager — a trigger fires on the keystroke that completes it, since the matcher cannot
/// know what the user will type next. A trigger that is a strict prefix of another (`:e` alongside
/// `:email`) therefore always wins; overlapping triggers like that are a library-authoring mistake
/// rather than something the matcher can resolve. The same goes for an open-ended regex: `//\d+`
/// fires on the first digit, never on the second.
///
/// Regex triggers cannot be walked backwards a character at a time, so they sit outside the trie and
/// are swept only once the walk has come up empty. What that ordering buys is precedence, not speed:
/// a plain trigger always beats a regex that would have completed on the same keystroke. It costs
/// speed, if anything. Most keystrokes complete no trigger, so most keystrokes reach the sweep, and
/// the sweep is linear in the number of regex snippets — each one an `NSRegularExpression` run over
/// the buffer. Plain triggers stay independent of library size; regex triggers are the thing to
/// spend sparingly.
public final class TriggerMatcher {

    /// Characters that count as a word delimiter for `wordBoundary` snippets.
    private static let wordDelimiters: Set<Character> = Set(" \t\n.,;:!?()[]{}<>\"'")

    /// A trigger registered at a trie node: the snippet to fire and the conditions to fire it under.
    private struct Entry {
        let snippetID: UUID
        let requiresWordBoundary: Bool
        let propagatesCase: Bool
        /// The trigger exactly as authored. The trie is keyed on the case-folded form so that one
        /// walk serves both kinds of trigger, which means the walk alone proves nothing about
        /// casing: this is what the typed text is actually judged against.
        let trigger: [Character]

        /// How the casing in `typed` should be carried onto the expansion, or `nil` if this entry
        /// may not fire for that casing at all.
        ///
        /// `typed` is the buffer suffix the walk matched, so it is the same length as `trigger`.
        func caseTransform(forTyped typed: ArraySlice<Character>) -> CaseTransform? {
            // The overwhelmingly common keystroke is the trigger typed as authored. Spelled out
            // because a bare `.none` in an optional return is `Optional.none` — that is, `nil`.
            if typed.elementsEqual(trigger) { return CaseTransform.none }
            guard propagatesCase else { return nil }

            var casedCount = 0
            var isCapitalised = true
            var isUppercased = true
            for (typedCharacter, canonical) in zip(typed, trigger) {
                guard canonical.isCased else {
                    // A character with no case — ":", "/", a digit — has to match literally.
                    guard typedCharacter == canonical else { return nil }
                    continue
                }
                guard typedCharacter.lowercased() == canonical.lowercased() else { return nil }
                casedCount += 1
                // Capitalising means the first cased letter went up and nothing else moved; a
                // trigger authored with capitals of its own keeps them.
                if casedCount == 1 ? !typedCharacter.isUppercase : typedCharacter != canonical {
                    isCapitalised = false
                }
                if !typedCharacter.isUppercase { isUppercased = false }
            }
            // Checked in this order so a single-letter trigger typed uppercase reads as a
            // capitalisation rather than a shout — there is nothing else there to shout.
            if isCapitalised && casedCount >= 1 { return .capitalised }
            if isUppercased && casedCount >= 2 { return .uppercased }
            return nil
        }
    }

    /// A regex trigger, compiled once at `setSnippets` time so no keystroke ever pays to parse it.
    private struct RegexEntry {
        let snippetID: UUID
        /// The author's pattern wrapped so that it can only match at the end of the buffer.
        let regex: NSRegularExpression
        let requiresWordBoundary: Bool
        /// Named groups, read off the pattern text: `NSRegularExpression` can look a group up by
        /// name but cannot list the names it compiled.
        let captureNames: [String]
    }

    /// A node in the reversed-trigger trie. Reference type so building the trie stays in place
    /// rather than copying nested dictionaries at every level.
    private final class Node {
        var children: [Character: Node] = [:]
        /// Triggers ending at this node, in `setSnippets` order — the tie-break among equal lengths.
        /// A list rather than a single entry because two snippets may share a trigger and disagree
        /// about `wordBoundary`, in which case the first *eligible* one wins.
        var entries: [Entry] = []
    }

    /// How far back the matcher can see. Also the longest trigger that can ever match, and the
    /// bound that keeps the per-keystroke walk cheap.
    private let maxBufferLength: Int

    /// The characters typed since the last reset or match, oldest first, capped at
    /// `maxBufferLength`.
    private var buffer: [Character] = []

    private var root = Node()

    /// Compiled regex triggers, in `setSnippets` order — the first one that matches wins, matching
    /// the trie's tie-break among triggers of equal length.
    private var regexEntries: [RegexEntry] = []

    /// - Parameter maxBufferLength: characters of typing history to keep. Values below 1 are
    ///   clamped, since a matcher that cannot hold a single character could never match anything.
    public init(maxBufferLength: Int = 64) {
        self.maxBufferLength = max(1, maxBufferLength)
        buffer.reserveCapacity(self.maxBufferLength)
    }

    /// Replaces the matchable set. The caller has already filtered out disabled snippets and
    /// groups that do not apply to the frontmost app.
    ///
    /// The typing buffer is deliberately left alone: the snippet library changing does not change
    /// what is on screen in front of the caret.
    public func setSnippets(_ snippets: [Snippet]) {
        let root = Node()
        var regexEntries: [RegexEntry] = []
        for snippet in snippets {
            // Regex triggers match against the whole buffer rather than a suffix, so they are not
            // trie material.
            if let pattern = snippet.regexTrigger {
                // Wrapped so the pattern can only match where it ends at the caret: `\z` anchors the
                // end, and the non-capturing group keeps an alternation at the top level of the
                // author's pattern from escaping it. Group numbers and names are untouched.
                //
                // An invalid pattern is dropped in silence: the editor validates before saving, and
                // inside the event tap one dead rule beats refusing to load the rest of the library.
                guard !pattern.isEmpty,
                      let regex = try? NSRegularExpression(pattern: "(?:\(pattern))\\z") else { continue }
                regexEntries.append(RegexEntry(snippetID: snippet.id, regex: regex,
                                               requiresWordBoundary: snippet.wordBoundary,
                                               captureNames: Self.captureNames(in: pattern)))
                continue
            }
            for trigger in snippet.triggers where !trigger.isEmpty {
                var node = root
                // Keyed case-folded so that a `propagateCase` trigger and an exact one can share a
                // single walk per keystroke. The entry, not the path, decides whether the casing
                // the user actually typed is acceptable.
                for character in trigger.reversed() {
                    let key = Self.foldedKey(for: character)
                    if let child = node.children[key] {
                        node = child
                    } else {
                        let child = Node()
                        node.children[key] = child
                        node = child
                    }
                }
                node.entries.append(Entry(snippetID: snippet.id,
                                          requiresWordBoundary: snippet.wordBoundary,
                                          propagatesCase: snippet.propagateCase,
                                          trigger: Array(trigger)))
            }
        }
        self.root = root
        self.regexEntries = regexEntries
    }

    /// Feeds one keystroke in, returning a match if this keystroke completed a trigger.
    ///
    /// A match empties the buffer, so the text the caller is about to delete cannot take part in a
    /// second, overlapping match.
    public func process(_ input: KeyInput) -> TriggerMatch? {
        switch input {
        case .reset:
            resetBuffer()
            return nil
        case .backspace:
            if !buffer.isEmpty { buffer.removeLast() }
            return nil
        case .character(let character):
            buffer.append(character)
            if buffer.count > maxBufferLength {
                buffer.removeFirst(buffer.count - maxBufferLength)
            }
            guard let match = longestEligibleMatch() ?? regexMatch() else { return nil }
            resetBuffer()
            return match
        }
    }

    /// Drops the typing history, so nothing typed so far can combine with what is typed next.
    public func resetBuffer() {
        buffer.removeAll(keepingCapacity: true)
    }

    /// Walks the trie backwards from the end of the buffer, keeping the longest trigger that is
    /// allowed to fire where it sits.
    ///
    /// Every step down the trie is one character longer than the last, so the deepest eligible
    /// entry found is the longest match. A trigger that is blocked where it sits — by its word
    /// boundary, or by a casing it does not accept — does not block a shorter one behind it: the
    /// walk keeps the best candidate it has already found.
    private func longestEligibleMatch() -> TriggerMatch? {
        var node = root
        var best: TriggerMatch?
        var index = buffer.count
        while index > 0 {
            index -= 1
            guard let child = node.children[Self.foldedKey(for: buffer[index])] else { break }
            node = child
            guard !node.entries.isEmpty else { continue }
            // A trigger starting at the very beginning of the buffer counts as following a
            // delimiter: whatever preceded it has been forgotten, and the alternative — never
            // firing there — would silently drop matches once the buffer has rolled over.
            let followsDelimiter = index == 0 || Self.wordDelimiters.contains(buffer[index - 1])
            for entry in node.entries {
                guard !entry.requiresWordBoundary || followsDelimiter,
                      let caseTransform = entry.caseTransform(forTyped: buffer[index...]) else { continue }
                best = TriggerMatch(snippetID: entry.snippetID, typedText: String(buffer[index...]),
                                    caseTransform: caseTransform)
                break
            }
        }
        return best
    }

    /// Runs the regex triggers against the buffer, returning the first that matches at the caret.
    ///
    /// Only reached once the trie walk has missed, and bounded by the buffer: the pattern is
    /// compiled already, and the one string this builds is at most `maxBufferLength` characters.
    ///
    /// `caseTransform` is always `.none` — a regex has no canonical trigger text to compare the
    /// typing against, so there is nothing to propagate.
    private func regexMatch() -> TriggerMatch? {
        guard !regexEntries.isEmpty else { return nil }
        let text = String(buffer)
        let searchRange = NSRange(text.startIndex..<text.endIndex, in: text)
        for entry in regexEntries {
            // A pattern that can match nothing — `\d*` — matches the empty string at the end of
            // every buffer. Firing on that would mean expanding on every keystroke with nothing to
            // delete, and, since a match empties the buffer, no other trigger could ever complete.
            guard let result = entry.regex.firstMatch(in: text, options: [], range: searchRange),
                  let matchedRange = Range(result.range, in: text), !matchedRange.isEmpty
            else { continue }
            // `wordBoundary` reads the same on a regex as on a plain trigger, buffer start included:
            // a pattern can spell its own boundary with `\b`, but the toggle in the editor should
            // not quietly do nothing for the snippets that have a regex.
            //
            // Judged on the one match the engine returned — the leftmost that ends at the caret. A
            // pattern that could also have matched further along, starting after a delimiter, is
            // still rejected; asking for that is what `\b` in the pattern is for.
            if entry.requiresWordBoundary, matchedRange.lowerBound != text.startIndex {
                let preceding = text[text.index(before: matchedRange.lowerBound)]
                guard Self.wordDelimiters.contains(preceding) else { continue }
            }
            var captures: [String: String] = [:]
            for name in entry.captureNames {
                guard let range = Range(result.range(withName: name), in: text) else { continue }
                captures[name] = String(text[range])
            }
            return TriggerMatch(snippetID: entry.snippetID, typedText: String(text[matchedRange]),
                                regexCaptures: captures)
        }
        return nil
    }

    /// The trie key for `character`: its lowercased form, where that is still a single character.
    ///
    /// Builds the trie and walks it, so the two can never drift apart. The single-character guard is
    /// defence rather than a case anyone reaches: even Turkish "İ", whose lowercase is two scalars,
    /// is one grapheme cluster and folds cleanly. But a trie key has to be one `Character`, and
    /// falling back to the character as typed is the safe way not to need one.
    private static func foldedKey(for character: Character) -> Character {
        // Lowercasing allocates a `String`, and only an uppercase or titlecase character can move.
        // Skipping it keeps the ordinary keystroke to a single dictionary probe.
        guard character.isCased, !character.isLowercase else { return character }
        let lowered = character.lowercased()
        guard lowered.count == 1 else { return character }
        return Character(lowered)
    }

    /// Matches the opening of a named capture group. The name character class excludes `=` and `!`,
    /// which is what keeps the lookbehinds `(?<=` and `(?<!` out.
    private static let namedGroupOpening = try? NSRegularExpression(
        pattern: #"\(\?<([A-Za-z][A-Za-z0-9]*)>"#)

    /// The named capture groups in `pattern`, in source order.
    ///
    /// Read off the pattern text because `NSRegularExpression` exposes no way to enumerate them. A
    /// name picked up from somewhere it is not really a group — inside a character class, say — is
    /// harmless: looking it up on a match yields `NSNotFound` and it is dropped.
    private static func captureNames(in pattern: String) -> [String] {
        guard let namedGroupOpening else { return [] }
        let range = NSRange(pattern.startIndex..<pattern.endIndex, in: pattern)
        return namedGroupOpening.matches(in: pattern, options: [], range: range).compactMap {
            Range($0.range(at: 1), in: pattern).map { String(pattern[$0]) }
        }
    }
}
