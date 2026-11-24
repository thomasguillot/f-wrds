import AppKit
import SwiftUI
import WrdsKit

/// A handle onto the live text view, for the two things SwiftUI cannot express as state: putting a
/// token in at the caret, and knowing where on screen the caret is.
///
/// Held by the view that owns the editor and handed back in, rather than being reached for through
/// the coordinator — an `NSViewRepresentable`'s coordinator is not something its parent is given.
@MainActor
final class ContentEditorController {
    fileprivate weak var coordinator: ContentEditorView.Coordinator?

    /// Inserts `token` where the caret is and returns the resulting chip's rectangle, in the editor's
    /// own coordinate space, for a popover to point at.
    ///
    /// `vocabulary` has to already know about the variable the token names — the caller has just
    /// created it, and SwiftUI will not have re-run `updateNSView` yet.
    @discardableResult
    func insert(token: String, vocabulary: ChipVocabulary) -> CGRect? {
        coordinator?.insert(token: token, vocabulary: vocabulary)
    }

    /// The next change to the text comes from undo or redo: put the caret where it lands and scroll
    /// it into view, as ⌘Z does in any text view.
    func revealNextChange() {
        coordinator?.revealsNextChange = true
    }
}

/// The snippet content editor: an `NSTextView` in which every `{{token}}` naming one of the snippet's
/// variables is drawn as a chip.
///
/// ## What is actually stored
///
/// The binding always carries the raw model string. Chips are presentation: the text storage is built
/// from the model string on the way in, and serialised back to it on every edit
/// (`TokenSerialiser`). Raw mode is the same string with the chip pass switched off, which is why the
/// two modes round-trip losslessly — there is only ever one string.
///
/// ## When the text storage is rebuilt
///
/// - **Wholesale**, from `updateNSView`, when the model string, the vocabulary, the font or the mode
///   changed from outside the text view — and on an appearance change, which invalidates every chip
///   image.
/// - **Surgically**, from `textDidChange`, when typing or pasting has completed a token. Chips are one
///   U+FFFC character each, so anything the token pattern still matches in the *displayed* string is
///   literal text that has just become a token, and only those ranges are replaced. That keeps typing
///   free of full rebuilds.
///
/// ## Undo
///
/// The text view records no undo of its own (`allowsUndo` is off): its history would be in display
/// ranges, which every wholesale rebuild invalidates. Each user edit is reported through `onTextEdit`
/// as a new model string instead, and the owning editor keeps the history on the window's undo
/// manager (`SnippetUndoController`). Undoing changes the binding, which comes back here as an
/// ordinary rebuild.
struct ContentEditorView: NSViewRepresentable {
    @Binding var text: String
    /// Which snippet the text belongs to. A different one starts at the top rather than keeping the
    /// previous snippet's caret.
    let documentID: UUID
    let vocabulary: ChipVocabulary
    /// The snippet's variables, for describing chips to VoiceOver.
    let variables: [Variable]
    let isRawMode: Bool
    let isMonospaced: Bool
    let controller: ContentEditorController
    /// A chip was clicked: its variable's name, and where it sits in this view.
    let onChipClicked: (String, CGRect) -> Void
    /// The user changed the text: the new model string, and whether the edit carries straight on from
    /// the previous one (more typing at the same caret, or more deleting), so a run of typing can be
    /// one undo step. Not called for tokens put in through `ContentEditorController`, which the caller
    /// records itself.
    let onTextEdit: (String, Bool) -> Void
    /// Editing finished — the moment the owning editor persists its draft.
    let onEndEditing: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    static func font(monospaced: Bool) -> NSFont {
        let size = NSFont.systemFontSize
        return monospaced
            ? .monospacedSystemFont(ofSize: size, weight: .regular)
            : .systemFont(ofSize: size)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSView {
        let host = FlippedHostView()
        let textView = Self.makeTextView(coordinator: context.coordinator)

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .lineBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: host.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])

        context.coordinator.attach(textView: textView, host: host)
        controller.coordinator = context.coordinator
        return host
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
        controller.coordinator = context.coordinator
        context.coordinator.apply(text: text, vocabulary: vocabulary, isRawMode: isRawMode,
                                  font: Self.font(monospaced: isMonospaced), isEnabled: isEnabled)
    }

    /// Takes whatever it is offered. A scroll view has no intrinsic size to fall back on, so without
    /// this the editor would be proposed the hosting view's fitting size — zero — and collapse.
    ///
    /// An infinite proposal is answered with the fallback rather than with infinity: SwiftUI asks for
    /// a view's maximum size that way, and a scroll view has no maximum worth naming.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: Self.resolve(proposal.width, fallback: 320),
               height: Self.resolve(proposal.height, fallback: 180))
    }

    private static func resolve(_ dimension: CGFloat?, fallback: CGFloat) -> CGFloat {
        guard let dimension, dimension.isFinite else { return fallback }
        return dimension
    }

    /// A TextKit 1 stack, built by hand.
    ///
    /// `NSTextView(frame:)` would give a TextKit 2 view, whose `textLayoutManager` has no equivalent
    /// of `boundingRect(forGlyphRange:in:)` — which is what turns a click into "that chip, there" and
    /// a caret into a rectangle a popover can point at. Attachments, selection and editing all behave
    /// the same either way; only the geometry questions this view has to ask are easier here.
    private static func makeTextView(coordinator: Coordinator) -> ChipTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let textView = ChipTextView(frame: .zero, textContainer: container)
        textView.delegate = coordinator
        textView.allowsUndo = false
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = CGSize.zero
        textView.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = CGSize(width: 4, height: 6)
        textView.onChipClick = { [weak coordinator] chip, index in
            coordinator?.chipClicked(chip, at: index)
        }
        textView.onAppearanceChange = { [weak coordinator] in coordinator?.appearanceChanged() }
        textView.describeChip = { [weak coordinator] chip in
            ChipVocabulary.spokenDescription(of: chip.token, in: coordinator?.parent.variables ?? [])
        }
        return textView
    }

    // MARK: The coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ContentEditorView

        private weak var textView: ChipTextView?
        private weak var host: NSView?
        private var vocabulary = ChipVocabulary()
        private var isRawMode = false
        private var font = ContentEditorView.font(monospaced: true)

        /// Set while this class is the one editing, so its own edits do not come back round through
        /// `textDidChange` as if the user had made them.
        private var isApplyingOwnEdit = false

        /// A rebuild `rebuild(with:)` refused to run because an input method had text marked. Flushed
        /// by `flushDeferredRebuild()` the moment the composition commits.
        private var hasDeferredRebuild = false

        private var isInsertingToken = false

        private var typingRun = TypingRun()
        private var documentID: UUID?
        var revealsNextChange = false

        init(parent: ContentEditorView) {
            self.parent = parent
        }

        func attach(textView: ChipTextView, host: NSView) {
            self.textView = textView
            self.host = host
        }

        private var baseAttributes: [NSAttributedString.Key: Any] {
            [.font: font, .foregroundColor: NSColor.labelColor]
        }

        // MARK: Following SwiftUI

        func apply(text: String, vocabulary: ChipVocabulary, isRawMode: Bool, font: NSFont,
                   isEnabled: Bool) {
            let documentID = parent.documentID
            guard let textView, let storage = textView.textStorage else { return }
            textView.isEditable = isEnabled
            let displayed = TokenSerialiser.rawString(from: storage)
            let isNewDocument = self.documentID != documentID
            let reveals = revealsNextChange && !isNewDocument && displayed != text
            let presentationChanged = self.vocabulary != vocabulary || self.isRawMode != isRawMode
                || self.font != font
            self.documentID = documentID
            self.vocabulary = vocabulary
            self.isRawMode = isRawMode
            self.font = font
            revealsNextChange = false
            guard isNewDocument || displayed != text || presentationChanged else { return }
            let changeEnd = reveals ? TokenSerialiser.endOfChange(from: displayed, to: text) : nil
            rebuild(with: text, rawCaret: isNewDocument ? 0 : changeEnd, reveal: reveals)
        }

        /// Replaces the whole text storage with `raw` rendered for the current mode, with the caret at
        /// `rawCaret` in the model string or, by default, where it was, scrolled to when `reveal`.
        ///
        /// **Never while an input method has text marked.** This is the one function that replaces the
        /// storage, so the composition guard lives here rather than being repeated at each caller —
        /// a choke point cannot be bypassed by a path someone adds later. Marked text is a guess that
        /// has not been committed and does not exist in the model yet: replacing the storage would
        /// throw it away while the input context still believed it had a marked range. The rebuild is
        /// remembered instead, and `flushDeferredRebuild()` runs it once the composition commits.
        private func rebuild(with raw: String, rawCaret requestedCaret: Int? = nil, reveal: Bool = false) {
            guard let textView, let storage = textView.textStorage else { return }
            guard !textView.hasMarkedText() else {
                hasDeferredRebuild = true
                return
            }
            let caret = min(textView.selectedRange().location, storage.length)
            let rawCaret = requestedCaret ?? TokenSerialiser.carry(
                (TokenSerialiser.rawString(
                    from: storage.attributedSubstring(from: NSRange(location: 0, length: caret))) as NSString)
                    .length,
                from: TokenSerialiser.rawString(from: storage), to: raw)
            let attributed = isRawMode
                ? NSAttributedString(string: raw, attributes: baseAttributes)
                : TokenSerialiser.attributedString(for: raw, vocabulary: vocabulary,
                                                   attributes: baseAttributes)
            isApplyingOwnEdit = true
            storage.setAttributedString(attributed)
            isApplyingOwnEdit = false
            textView.typingAttributes = baseAttributes
            typingRun.reset()

            let chips = isRawMode ? [] : TokenSerialiser.chips(in: raw, vocabulary: vocabulary)
            let target = TokenSerialiser.displayOffset(
                forRaw: min(rawCaret, (raw as NSString).length), chips: chips)
            let selection = NSRange(location: min(target, attributed.length), length: 0)
            textView.setSelectedRange(selection)
            if reveal { textView.scrollRangeToVisible(selection) }
            NSAccessibility.post(element: textView, notification: .layoutChanged)
        }

        /// Rebuilds after light or dark mode changed, which every chip image was drawn for.
        ///
        /// From the model, not from what is on screen. Reading the display back and writing it in
        /// again would make whatever the display happened to hold authoritative — including an
        /// uncommitted composition — and this path pushes nothing to the binding, so a difference
        /// would never be corrected.
        func appearanceChanged() {
            guard !isRawMode, textView != nil else { return }
            let raw = parent.text
            guard !TokenSerialiser.chips(in: raw, vocabulary: vocabulary).isEmpty else { return }
            rebuild(with: raw)
        }

        // MARK: Following the text view

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                      replacementString: String?) -> Bool {
            if !isApplyingOwnEdit {
                typingRun.willChange(affectedCharRange,
                                     replacementLength: (replacementString as NSString?)?.length ?? 0)
            }
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingOwnEdit, let textView, let storage = textView.textStorage else { return }
            // Mid-composition the marked text is a guess the input method has not committed yet.
            // Serialising it would push half a character into the model and re-tokenising it would
            // pull the composition out from under the input method.
            guard !textView.hasMarkedText() else { return }
            tokeniseTypedTokens()
            let continuing = typingRun.didChange(caret: textView.selectedRange().location)
            let raw = TokenSerialiser.rawString(from: storage)
            if raw != parent.text {
                parent.text = raw
                if !isInsertingToken { parent.onTextEdit(raw, continuing) }
            }
            flushDeferredRebuild()
        }

        /// Runs a rebuild that was put off because an input method had text marked.
        ///
        /// Rebuilt from the model **as it stands now** — the composition has just been committed and
        /// pushed there by the line above — rather than replayed from the string the rebuild was
        /// originally asked for, which was captured before the composition existed and would discard
        /// it. What the deferred rebuild is really carrying is the new vocabulary, mode and font,
        /// which `apply` stored on its way past; the content it applies them to is the user's.
        private func flushDeferredRebuild() {
            guard hasDeferredRebuild else { return }
            hasDeferredRebuild = false
            rebuild(with: parent.text)
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.onEndEditing()
        }

        /// Turns tokens that have just been typed or pasted into chips, in place.
        private func tokeniseTypedTokens() {
            guard !isRawMode, let textView, let storage = textView.textStorage else { return }
            let typed = TokenSerialiser.chips(in: storage.string, vocabulary: vocabulary)
            guard !typed.isEmpty else { return }

            let caret = textView.selectedRange().location
            isApplyingOwnEdit = true
            // Back to front, so each replacement leaves the ranges still to come untouched.
            for token in typed.reversed() {
                let chip = TokenSerialiser.chip(for: token, vocabulary: vocabulary,
                                                attributes: baseAttributes)
                guard textView.shouldChangeText(in: token.range, replacementString: chip.string)
                else { continue }
                storage.replaceCharacters(in: token.range, with: chip)
                textView.didChangeText()
            }
            isApplyingOwnEdit = false
            textView.typingAttributes = baseAttributes
            NSAccessibility.post(element: textView, notification: .layoutChanged)

            let shift = typed
                .filter { $0.range.location + $0.range.length <= caret }
                .reduce(0) { $0 + $1.range.length - 1 }
            let location = max(0, min(caret - shift, storage.length))
            textView.setSelectedRange(NSRange(location: location, length: 0))
        }

        // MARK: Insertion and hit-testing

        func insert(token: String, vocabulary: ChipVocabulary) -> CGRect? {
            guard let textView, textView.isEditable else { return nil }
            // The variable this token names was created a moment ago and SwiftUI has not come back
            // round yet, so the vocabulary the tokeniser is about to consult is set here.
            self.vocabulary = vocabulary
            // Any half-finished composition becomes ordinary text before a token is dropped in beside
            // it. `insertText` with an explicit replacement range while an input method still held a
            // marked range would leave the two disagreeing about what is where.
            if textView.hasMarkedText() { textView.unmarkText() }
            textView.window?.makeFirstResponder(textView)
            isInsertingToken = true
            textView.insertText(NSAttributedString(string: token, attributes: baseAttributes),
                                replacementRange: textView.selectedRange())
            isInsertingToken = false
            typingRun.reset()
            // `insertText` ends in `didChangeText()`, so by now the token has been chipped and the
            // model string pushed — the chip is the character the caret has just moved past.
            let caret = textView.selectedRange().location
            guard caret > 0 else { return nil }
            return chipRect(at: caret - 1)
        }

        func chipClicked(_ chip: TokenChipAttachment, at index: Int) {
            guard let rect = chipRect(at: index) else { return }
            parent.onChipClicked(chip.token.name, rect)
        }

        /// Where the character at `index` sits, in the hosting view's coordinates — which are
        /// top-left origin like SwiftUI's, because `FlippedHostView` is flipped.
        private func chipRect(at index: Int) -> CGRect? {
            guard let textView, let host, let layoutManager = textView.layoutManager,
                  let container = textView.textContainer,
                  index >= 0, index < (textView.textStorage?.length ?? 0) else { return nil }
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
            rect.origin.x += textView.textContainerOrigin.x
            rect.origin.y += textView.textContainerOrigin.y
            return host.convert(rect, from: textView)
        }
    }
}

/// Top-left origin, so a rectangle measured in the text view converts straight into the coordinate
/// space SwiftUI anchors a popover in.
private final class FlippedHostView: NSView {
    override var isFlipped: Bool { true }
}
