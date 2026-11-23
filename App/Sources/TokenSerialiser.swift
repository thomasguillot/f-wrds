import AppKit
import Foundation
import WrdsKit

/// The translation between the `{{token}}` text a snippet actually stores and the chip-bearing
/// attributed string `ContentEditorView` puts on screen.
///
/// **The model string is the source of truth, always.** A chip is an `NSTextAttachment` carrying the
/// token exactly as it was authored, and serialising simply puts that text back where the attachment
/// stood — so `{{ name }}` with its spaces survives a trip through the editor, and raw mode and chip
/// mode are the same string shown two ways. Nothing here ever rewrites a token except
/// `renaming(_:to:in:)`, which is asked to.
///
/// **Only tokens naming a variable the snippet declares become chips.** Everything else — a typo, or
/// a global referenced directly rather than through a local `.global` variable — stays as literal,
/// editable text.
///
/// Not because such a token means nothing at expansion time. It usually does:
/// `ExpansionRenderer` resolves a name against the snippet's variables, *then* the library's globals,
/// *then* the regex captures, so a bare `{{signature}}` naming a global expands perfectly well and
/// the preview pane shows it doing so. The reason is narrower and about this editor only: a chip's
/// whole affordance is that clicking it opens the variable it stands for, and that is only true of
/// names this snippet declares. Widening the vocabulary means answering what clicking the new kind of
/// chip does — read-only for a global, "create one?" for a typo — before it is worth doing.
enum TokenSerialiser {

    /// `{{name}}` or `{{name.field}}`, tolerating spaces inside the braces.
    ///
    /// Deliberately the same pattern `ExpansionRenderer` substitutes with, so the editor recognises a
    /// token exactly where the renderer will — `{{1bad}}` is prose to both. Which of those tokens
    /// become chips is narrower again; see the note on this type. Optional for the same reason it is
    /// there — a pattern is a runtime value, and a failure to compile it should cost chips rather than
    /// the whole editor.
    private static let tokenPattern = try? NSRegularExpression(
        pattern: #"\{\{\s*([A-Za-z_][\w-]*)(?:\.([A-Za-z_][\w-]*))?\s*\}\}"#)

    /// What a variable name may be spelled with, anchored end to end. Narrower than the token
    /// pattern's `\w` on purpose: `\w` is Unicode-aware and would accept names that survive here but
    /// read badly in an Espanso export.
    private static let namePattern = try? NSRegularExpression(
        pattern: #"\A[A-Za-z_][A-Za-z0-9_-]*\z"#)

    /// One `{{token}}` found in a string, with everything the editor needs to draw it or put it back.
    struct Token: Equatable {
        /// Where it sits, in UTF-16 units of the string it was found in — the unit `NSTextStorage`
        /// and `NSRange` count in.
        var range: NSRange
        var name: String
        var field: String?
        /// The token exactly as authored. Serialising a chip writes this, not a re-spelling of it.
        var raw: String

        /// What the chip reads: `name`, or `name.field` when the token addresses a form field.
        var label: String { field.map { "\(name).\($0)" } ?? name }
    }

    // MARK: Reading tokens

    /// Every syntactically valid token in `text`, in the order they appear.
    static func tokens(in text: String) -> [Token] {
        guard let tokenPattern, text.contains("{{") else { return [] }
        let string = text as NSString
        let matches = tokenPattern.matches(in: text, range: NSRange(location: 0, length: string.length))
        return matches.compactMap { match in
            let nameRange = match.range(at: 1)
            guard nameRange.location != NSNotFound else { return nil }
            let fieldRange = match.range(at: 2)
            return Token(
                range: match.range,
                name: string.substring(with: nameRange),
                field: fieldRange.location == NSNotFound ? nil : string.substring(with: fieldRange),
                raw: string.substring(with: match.range))
        }
    }

    /// The tokens in `text` that name a variable — the ones that become chips.
    static func chips(in text: String, vocabulary: ChipVocabulary) -> [Token] {
        guard !vocabulary.isEmpty else { return [] }
        return tokens(in: text).filter { vocabulary.contains($0.name) }
    }

    /// Whether `name` is a legal variable name.
    static func isValidName(_ name: String) -> Bool {
        guard let namePattern, !name.isEmpty else { return false }
        let range = NSRange(location: 0, length: (name as NSString).length)
        return namePattern.firstMatch(in: name, range: range) != nil
    }

    /// `prefix1`, `prefix2`, … — the first name of that shape nothing has taken.
    static func uniqueName(prefix: String, taken: Set<String>) -> String {
        var suffix = 1
        while taken.contains("\(prefix)\(suffix)") { suffix += 1 }
        return "\(prefix)\(suffix)"
    }

    // MARK: Model string ⇄ attributed string

    /// The attributed string that shows `raw` with its known tokens drawn as chips.
    static func attributedString(for raw: String, vocabulary: ChipVocabulary,
                                 attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let string = raw as NSString
        var cursor = 0
        for token in chips(in: raw, vocabulary: vocabulary) {
            if token.range.location > cursor {
                let plain = string.substring(
                    with: NSRange(location: cursor, length: token.range.location - cursor))
                output.append(NSAttributedString(string: plain, attributes: attributes))
            }
            output.append(chip(for: token, vocabulary: vocabulary, attributes: attributes))
            cursor = token.range.location + token.range.length
        }
        if cursor < string.length {
            output.append(NSAttributedString(string: string.substring(from: cursor), attributes: attributes))
        }
        return output
    }

    /// One chip, as the single attachment character it occupies.
    static func chip(for token: Token, vocabulary: ChipVocabulary,
                     attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let font = attributes[.font] as? NSFont ?? .systemFont(ofSize: NSFont.systemFontSize)
        let attachment = TokenChipAttachment(
            token: token, symbol: vocabulary.symbol(for: token.name), font: font)
        let chip = NSMutableAttributedString(attachment: attachment)
        var chipAttributes = attributes
        // The raw token as a tooltip, so the exact text a chip stands for is readable without
        // switching the whole editor into raw mode.
        chipAttributes[.toolTip] = token.raw
        chip.addAttributes(chipAttributes, range: NSRange(location: 0, length: chip.length))
        return chip
    }

    /// The model string an attributed string stands for: every chip back to its token, everything
    /// else verbatim.
    ///
    /// A foreign attachment — an image dropped in past `importsGraphics = false`, say — is dropped
    /// rather than left behind as a bare U+FFFC, which would otherwise be saved into the snippet and
    /// then typed into someone's document.
    static func rawString(from attributed: NSAttributedString) -> String {
        let string = attributed.string as NSString
        var output = ""
        attributed.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: attributed.length), options: []
        ) { value, range, _ in
            if let chip = value as? TokenChipAttachment {
                // Once per character of the run, not once per run. Attribute runs are coalesced on
                // the value's own equality, so two adjacent chips that ever came to share one
                // attachment object would arrive here as a single run of length two — and emitting
                // the token once would silently drop the other from the saved snippet.
                for _ in 0..<range.length { output += chip.token.raw }
            } else if value == nil {
                output += string.substring(with: range)
            }
        }
        return output
    }

    /// Where a model-string offset lands once the chips have collapsed to one character each. Both
    /// offsets are UTF-16.
    ///
    /// An offset *inside* a token collapses onto the chip's leading edge: there is no position
    /// halfway through a chip for a caret to be at.
    static func displayOffset(forRaw rawOffset: Int, chips: [Token]) -> Int {
        var offset = rawOffset
        for token in chips {
            let end = token.range.location + token.range.length
            if end <= rawOffset {
                offset -= token.range.length - 1
            } else if token.range.location < rawOffset {
                offset -= rawOffset - token.range.location
                break
            } else {
                break
            }
        }
        return offset
    }

    // MARK: Renaming

    /// `raw` with every `{{old}}` / `{{old.field}}` respelled to `new`, and every other token, and all
    /// the prose between them, left exactly as it was.
    ///
    /// A renamed token is rewritten in its canonical spelling, so `{{ old }}` comes back as `{{new}}`:
    /// the field name is carried across, the spacing inside the braces is not. Tokens that survive a
    /// rename untouched keep whatever spacing they were authored with.
    static func renaming(_ old: String, to new: String, in raw: String) -> String {
        let matched = tokens(in: raw).filter { $0.name == old }
        guard !matched.isEmpty else { return raw }
        let output = NSMutableString(string: raw)
        // Back to front, so each replacement leaves the ranges still to come untouched.
        for token in matched.reversed() {
            let replacement = token.field.map { "{{\(new).\($0)}}" } ?? "{{\(new)}}"
            output.replaceCharacters(in: token.range, with: replacement)
        }
        return output as String
    }
}
