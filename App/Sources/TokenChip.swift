import AppKit
import WrdsKit

/// Which token names the content editor draws as chips, and the symbol each one wears.
///
/// Built from the snippet's own variables only — see `TokenSerialiser` for why a token naming
/// anything else stays as plain text. Equatable so the editor can tell a change that alters how a
/// chip looks (a rename, a new variable, a different kind) from one that does not (typing into a
/// shell command), and rebuild its text storage only for the former.
struct ChipVocabulary: Equatable {
    private let symbols: [String: String]

    init(variables: [Variable] = []) {
        // First declaration of a name wins, matching how `ExpansionRenderer` resolves one.
        symbols = Dictionary(variables.map { ($0.name, Self.symbol(for: $0.kind)) },
                             uniquingKeysWith: { first, _ in first })
    }

    var isEmpty: Bool { symbols.isEmpty }
    func contains(_ name: String) -> Bool { symbols[name] != nil }
    func symbol(for name: String) -> String? { symbols[name] }

    /// The SF Symbol that stands for a kind — the same vocabulary the Insert Variable menu uses, so a
    /// chip and the menu item that made it read as the same thing.
    static func symbol(for kind: Variable.Kind) -> String {
        switch kind {
        case .date: return "calendar"
        case .clipboard: return "doc.on.clipboard"
        case .choice: return "shuffle"
        case .echo: return "text.quote"
        case .shell: return "terminal"
        case .form: return "list.bullet.rectangle"
        case .global: return "globe"
        }
    }
}

/// One `{{token}}` drawn as a capsule inside the content editor.
///
/// An attachment is a single character as far as the text system is concerned, which is the whole
/// reason chips are built this way: selecting, arrowing over and deleting one is atomic for free,
/// and nothing has to police a caret landing in the middle of a token.
///
/// The capsule is a pre-rendered `NSImage` rather than an `NSTextAttachmentCell`. Cells draw
/// themselves on demand — which would pick up an appearance change with no help — but they are
/// TextKit 1 only and are steadily being left behind; an image works under either text system. What
/// that costs is that the image has to be re-made when the effective appearance changes, which
/// `ContentEditorView`'s coordinator does by rebuilding the whole text storage.
final class TokenChipAttachment: NSTextAttachment {
    let token: TokenSerialiser.Token

    init(token: TokenSerialiser.Token, symbol: String?, font: NSFont) {
        self.token = token
        super.init(data: nil, ofType: nil)
        let drawn = TokenChipImage.make(label: token.label, symbol: symbol, font: font)
        image = drawn.image
        bounds = drawn.bounds
    }

    /// Chips are built from the model string every time the editor opens and are never archived.
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TokenChipAttachment is built from a token, never decoded.")
    }
}

/// Draws the capsule a chip shows.
enum TokenChipImage {
    private static let horizontalPadding: CGFloat = 7
    private static let verticalPadding: CGFloat = 2
    private static let symbolGap: CGFloat = 4

    /// The app's own accent, which is a colour asset with a light and a dark variant — hence the
    /// rebuild whenever the effective appearance changes. Falls back to the system tint if the asset
    /// is ever missing, so a chip is never invisible.
    static var accentColour: NSColor { NSColor(named: "AccentColor") ?? .controlAccentColor }

    /// The capsule, and the bounds it should occupy relative to the text baseline.
    ///
    /// The label is drawn in `labelColor` rather than in the accent: the accent here is a warm red,
    /// and accent-on-accent-tint is the one combination that stops being legible as the tint gets
    /// stronger. The symbol carries the colour instead, where a low-contrast glyph costs recognition
    /// rather than readability.
    static func make(label: String, symbol: String?, font: NSFont) -> (image: NSImage, bounds: CGRect) {
        let accent = accentColour
        let labelFont = NSFont.systemFont(ofSize: max(9, font.pointSize - 1), weight: .medium)
        let text = NSAttributedString(string: label, attributes: [
            .font: labelFont,
            .foregroundColor: NSColor.labelColor,
        ])
        let textSize = text.size()
        let symbolImage = symbol.flatMap { tinted(symbolNamed: $0, pointSize: labelFont.pointSize) }
        let symbolWidth = symbolImage.map { $0.size.width + symbolGap } ?? 0
        let size = CGSize(
            width: ceil(textSize.width + symbolWidth + horizontalPadding * 2),
            height: ceil(labelFont.ascender - labelFont.descender + verticalPadding * 2))

        let image = NSImage(size: size, flipped: false) { rect in
            // Inset by half the line width so the stroke lands inside the image rather than being
            // clipped in half by its edge.
            let capsule = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                       xRadius: (rect.height - 1) / 2, yRadius: (rect.height - 1) / 2)
            accent.withAlphaComponent(0.16).setFill()
            capsule.fill()
            accent.withAlphaComponent(0.5).setStroke()
            capsule.lineWidth = 1
            capsule.stroke()
            if let symbolImage {
                symbolImage.draw(in: CGRect(
                    x: horizontalPadding, y: (rect.height - symbolImage.size.height) / 2,
                    width: symbolImage.size.width, height: symbolImage.size.height))
            }
            text.draw(at: CGPoint(x: horizontalPadding + symbolWidth, y: verticalPadding))
            return true
        }

        // Centred on the cap height rather than sat on the baseline, so a chip reads as being on the
        // same line as the words either side of it instead of hanging below them.
        let bounds = CGRect(x: 0, y: font.capHeight / 2 - size.height / 2,
                            width: size.width, height: size.height)
        return (image, bounds)
    }

    /// An SF Symbol filled with the accent colour. `nil` when the symbol is not on this system, which
    /// leaves the chip as a capsule with a label — smaller, but never blank.
    private static func tinted(symbolNamed name: String, pointSize: CGFloat) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }
        let accent = accentColour
        return NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            accent.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}
