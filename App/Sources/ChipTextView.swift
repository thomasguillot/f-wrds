import AppKit

/// The text view itself: chip clicks, a pasteboard that speaks model strings, and chips VoiceOver can
/// read and open.
///
/// Copy writes the tokens a chip stands for rather than the U+FFFC it occupies, and paste comes back
/// in as plain text for `textDidChange` to re-tokenise — so a chip survives being cut and pasted, and
/// a `{{token}}` copied out of a config file arrives as a chip.
///
/// ## VoiceOver
///
/// A chip is an image attachment, which VoiceOver reads as nothing. Three things fix that:
/// - The text VoiceOver reads (`accessibilityString(for:)` and its attributed twin) has each chip's
///   U+FFFC replaced by what the chip is, so reading by character, word or line speaks it in place.
/// - Each chip is also a child button, in text order, that opens its settings when pressed.
/// - The text view offers a "Configure …" action per variable, for the VoiceOver actions menu.
final class ChipTextView: NSTextView {
    var onChipClick: ((TokenChipAttachment, Int) -> Void)?
    var onAppearanceChange: (() -> Void)?
    /// What VoiceOver says for a chip. Asked each time, so it follows the variable's current settings.
    var describeChip: ((TokenChipAttachment) -> String)?

    private var chipElements: [ObjectIdentifier: ChipAccessibilityElement] = [:]

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = characterIndex(at: point),
           let chip = textStorage?.attribute(.attachment, at: index, effectiveRange: nil)
            as? TokenChipAttachment {
            openChip(chip, at: index)
            return
        }
        super.mouseDown(with: event)
    }

    /// Selects the chip as well as opening its popover: it has to look like the thing being
    /// configured, and leave ⌫ pointed at it.
    private func openChip(_ chip: TokenChipAttachment, at index: Int) {
        window?.makeFirstResponder(self)
        setSelectedRange(NSRange(location: index, length: 1))
        onChipClick?(chip, index)
    }

    /// The character `point` is actually on top of, or `nil` if it is past the end of a line —
    /// `glyphIndex(for:in:)` answers with the nearest glyph rather than admitting a miss, so the hit
    /// is confirmed against that glyph's own rectangle.
    private func characterIndex(at point: CGPoint) -> Int? {
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0
        else { return nil }
        let origin = textContainerOrigin
        let inContainer = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        var fraction: CGFloat = 0
        let glyphIndex = layoutManager.glyphIndex(for: inContainer, in: textContainer,
                                                  fractionOfDistanceThroughGlyph: &fraction)
        let bounds = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1),
                                                in: textContainer)
        guard bounds.contains(inContainer) else { return nil }
        let index = layoutManager.characterIndexForGlyph(at: glyphIndex)
        return index < storage.length ? index : nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string, let storage = textStorage else {
            return super.writeSelection(to: pboard, type: type)
        }
        let selection = storage.attributedSubstring(from: selectedRange())
        pboard.setString(TokenSerialiser.rawString(from: selection), forType: .string)
        return true
    }

    // MARK: Accessibility

    /// Every chip in the text, in order, with the character it occupies.
    private func chips(in range: NSRange? = nil) -> [(chip: TokenChipAttachment, index: Int)] {
        guard let storage = textStorage else { return [] }
        let whole = NSRange(location: 0, length: storage.length)
        var found: [(TokenChipAttachment, Int)] = []
        storage.enumerateAttribute(.attachment, in: range ?? whole) { value, run, _ in
            guard let chip = value as? TokenChipAttachment else { return }
            for index in run.location..<NSMaxRange(run) { found.append((chip, index)) }
        }
        return found
    }

    private func chip(_ id: ObjectIdentifier) -> (chip: TokenChipAttachment, index: Int)? {
        chips().first { ObjectIdentifier($0.chip) == id }
    }

    private func description(of chip: TokenChipAttachment) -> String {
        describeChip?(chip) ?? chip.token.label
    }

    fileprivate func description(ofChip id: ObjectIdentifier) -> String? {
        chip(id).map { description(of: $0.chip) }
    }

    fileprivate func openChip(_ id: ObjectIdentifier) -> Bool {
        guard let found = chip(id) else { return false }
        openChip(found.chip, at: found.index)
        return true
    }

    /// The chip's rectangle on screen, which is what accessibility frames are measured in.
    fileprivate func screenFrame(ofChip id: ObjectIdentifier) -> CGRect {
        guard let index = chip(id)?.index, let layoutManager, let textContainer else { return .zero }
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: index, length: 1),
                                              actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        return NSAccessibility.screenRect(fromView: self, rect: rect)
    }

    /// `text` with the chip characters in `range` spelled out, back to front so each replacement
    /// leaves the offsets still to come where they were.
    private func spellingOutChips(_ text: NSAttributedString, from range: NSRange) -> NSAttributedString {
        let spoken = NSMutableAttributedString(attributedString: text)
        for (chip, index) in chips(in: range).reversed() {
            let offset = index - range.location
            guard offset >= 0, offset < spoken.length else { continue }
            var attributes = spoken.attributes(at: offset, effectiveRange: nil)
            attributes.removeValue(forKey: .attachment)
            attributes.removeValue(forKey: .accessibilityAttachment)
            spoken.replaceCharacters(in: NSRange(location: offset, length: 1),
                                     with: NSAttributedString(string: " \(description(of: chip)) ",
                                                              attributes: attributes))
        }
        return spoken
    }

    override func accessibilityString(for range: NSRange) -> String? {
        guard let storage = textStorage, NSMaxRange(range) <= storage.length else {
            return super.accessibilityString(for: range)
        }
        return spellingOutChips(storage.attributedSubstring(from: range), from: range).string
    }

    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        guard let text = super.accessibilityAttributedString(for: range), text.length == range.length
        else { return super.accessibilityAttributedString(for: range) }
        return spellingOutChips(text, from: range)
    }

    override func accessibilityChildren() -> [Any]? {
        let current = chips()
        let live = Set(current.map { ObjectIdentifier($0.chip) })
        chipElements = chipElements.filter { live.contains($0.key) }
        let elements: [Any] = current.map { chip, _ in
            if let existing = chipElements[ObjectIdentifier(chip)] { return existing }
            let element = ChipAccessibilityElement(chipID: ObjectIdentifier(chip), textView: self)
            chipElements[ObjectIdentifier(chip)] = element
            return element
        }
        return (super.accessibilityChildren() ?? []) + elements
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        var seen = Set<String>()
        let actions = chips().compactMap { chip, _ -> NSAccessibilityCustomAction? in
            guard seen.insert(chip.token.label).inserted else { return nil }
            return NSAccessibilityCustomAction(
                name: String(localized: "Configure \(chip.token.label)")
            ) { [weak self, id = ObjectIdentifier(chip)] in
                self?.openChip(id) ?? false
            }
        }
        return (super.accessibilityCustomActions() ?? []) + actions
    }
}

/// One chip as VoiceOver sees it: a button named for the variable, which opens its settings.
///
/// AppKit makes every accessibility call on the main thread, which `assumeIsolated` asserts.
private final class ChipAccessibilityElement: NSAccessibilityElement {
    private let chipID: ObjectIdentifier
    private weak var textView: ChipTextView?

    init(chipID: ObjectIdentifier, textView: ChipTextView) {
        self.chipID = chipID
        self.textView = textView
        super.init()
        setAccessibilityRole(.button)
        setAccessibilityParent(textView)
    }

    override func accessibilityLabel() -> String? {
        let (textView, id) = (textView, chipID)
        return MainActor.assumeIsolated { textView?.description(ofChip: id) }
    }

    override func accessibilityHelp() -> String? {
        String(localized: "Configure this variable")
    }

    override func accessibilityFrame() -> NSRect {
        let (textView, id) = (textView, chipID)
        return MainActor.assumeIsolated { textView?.screenFrame(ofChip: id) ?? .zero }
    }

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityPerformPress() -> Bool {
        let (textView, id) = (textView, chipID)
        return MainActor.assumeIsolated { textView?.openChip(id) ?? false }
    }
}
