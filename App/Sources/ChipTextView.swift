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
/// - Each chip is a child button, in text order, named for its variable, that opens its settings
///   when pressed.
/// - The text VoiceOver reads marks each chip's U+FFFC as that button, so reading by character, word
///   or line speaks it in place.
/// - The text view offers a "Configure …" action per variable, for the VoiceOver actions menu.
final class ChipTextView: NSTextView {
    var onChipClick: ((TokenChipAttachment, Int) -> Void)?
    var onAppearanceChange: (() -> Void)?
    /// What VoiceOver says for a chip. Asked each time, so it follows the variable's current settings.
    var describeChip: ((TokenChipAttachment) -> String)?

    private var chipElements: [ChipElementEntry] = []

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
    private func chips() -> [(chip: TokenChipAttachment, index: Int)] {
        guard let storage = textStorage else { return [] }
        var found: [(TokenChipAttachment, Int)] = []
        let whole = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.attachment, in: whole) { value, run, _ in
            guard let chip = value as? TokenChipAttachment else { return }
            for index in run.location..<NSMaxRange(run) { found.append((chip, index)) }
        }
        return found
    }

    /// One element per chip, in text order. Elements are kept for as long as their chip is in the
    /// text, so VoiceOver meets the same object on every query.
    private func chipElementsInOrder() -> [(index: Int, element: ChipAccessibilityElement)] {
        let current = chips()
        chipElements.removeAll { entry in !current.contains { $0.chip === entry.chip } }
        return current.map { chip, index in
            if let entry = chipElements.first(where: { $0.chip === chip }) {
                return (index, entry.element)
            }
            let element = ChipAccessibilityElement(textView: self)
            chipElements.append(ChipElementEntry(chip: chip, element: element))
            return (index, element)
        }
    }

    private func chip(for element: ObjectIdentifier) -> (chip: TokenChipAttachment, index: Int)? {
        guard let chip = chipElements.first(where: { ObjectIdentifier($0.element) == element })?.chip
        else { return nil }
        return chips().first { $0.chip === chip }
    }

    fileprivate func label(for element: ObjectIdentifier) -> String? {
        chip(for: element).map { describeChip?($0.chip) ?? $0.chip.token.label }
    }

    fileprivate func open(for element: ObjectIdentifier) -> Bool {
        guard let found = chip(for: element) else { return false }
        openChip(found.chip, at: found.index)
        return true
    }

    /// The chip's rectangle on screen, which is what accessibility frames are measured in.
    fileprivate func screenFrame(for element: ObjectIdentifier) -> CGRect {
        guard let index = chip(for: element)?.index, let layoutManager, let textContainer else { return .zero }
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: index, length: 1),
                                              actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        return NSAccessibility.screenRect(fromView: self, rect: rect)
    }

    /// Each chip keeps its one U+FFFC, so character ranges still match the text for Voice Control and
    /// Dictation; the attachment attribute points VoiceOver at the chip's element, whose label it
    /// speaks.
    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        guard let text = super.accessibilityAttributedString(for: range) else { return nil }
        guard text.length == range.length else { return text }
        let marked = NSMutableAttributedString(attributedString: text)
        for (index, element) in chipElementsInOrder() where NSLocationInRange(index, range) {
            marked.addAttribute(.accessibilityAttachment, value: element,
                                range: NSRange(location: index - range.location, length: 1))
        }
        return marked
    }

    override func accessibilityChildren() -> [Any]? {
        (super.accessibilityChildren() ?? []) + chipElementsInOrder().map(\.element)
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        var seen = Set<String>()
        let actions = chips().compactMap { chip, _ -> NSAccessibilityCustomAction? in
            guard seen.insert(chip.token.label).inserted else { return nil }
            return NSAccessibilityCustomAction(
                name: String(localized: "Configure \(chip.token.label)")
            ) { [weak self, weak chip] in
                guard let self, let chip, let found = chips().first(where: { $0.chip === chip })
                else { return false }
                openChip(found.chip, at: found.index)
                return true
            }
        }
        return (super.accessibilityCustomActions() ?? []) + actions
    }
}

private struct ChipElementEntry {
    weak var chip: TokenChipAttachment?
    let element: ChipAccessibilityElement
}

/// One chip as VoiceOver sees it: a button named for the variable, which opens its settings.
///
/// It names itself to the text view by identity, which is stable because the text view holds it.
/// AppKit makes every accessibility call on the main thread, which `assumeIsolated` asserts.
private final class ChipAccessibilityElement: NSAccessibilityElement {
    private weak var textView: ChipTextView?

    init(textView: ChipTextView) {
        self.textView = textView
        super.init()
        setAccessibilityRole(.button)
        setAccessibilityParent(textView)
    }

    override func accessibilityLabel() -> String? {
        let (textView, id) = (textView, ObjectIdentifier(self))
        return MainActor.assumeIsolated { textView?.label(for: id) }
    }

    override func accessibilityHelp() -> String? {
        String(localized: "Configure this variable")
    }

    override func accessibilityFrame() -> NSRect {
        let (textView, id) = (textView, ObjectIdentifier(self))
        return MainActor.assumeIsolated { textView?.screenFrame(for: id) ?? .zero }
    }

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityPerformPress() -> Bool {
        let (textView, id) = (textView, ObjectIdentifier(self))
        return MainActor.assumeIsolated { textView?.open(for: id) ?? false }
    }
}
