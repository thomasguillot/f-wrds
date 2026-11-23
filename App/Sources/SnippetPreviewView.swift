import SwiftUI
import WrdsKit

/// The stand-ins the preview renders with, in place of the four things a real expansion reaches for.
///
/// A plain enum rather than statics on the view, so they can be read from inside the `@Sendable`
/// closures a `RenderContext` is made of.
private enum PreviewPlaceholder {
    /// What a shell variable shows *instead of running*. The preview re-renders on every keystroke;
    /// a `RenderContext` that actually ran commands would run the user's shell once per character
    /// typed, which for anything with a side effect is unforgivable.
    static let shell = String(localized: "\u{2318} runs on expand")
    /// The clipboard is not read either — the preview is not worth a pasteboard access, and reading
    /// one here would show whatever happens to be copied rather than what will be.
    static let clipboard = String(localized: "(clipboard)")
    /// Where the caret lands, spelled U+258C LEFT HALF BLOCK.
    static let caret = "\u{258C}"
}

/// What this snippet will actually type, live, under the editor.
///
/// Renders the *draft* — the unsaved state of whatever is being edited above — through the same
/// `ExpansionRenderer` the engine uses, so dates, echoes, choices, globals and form tokens are
/// resolved by the real code rather than by a second, lying implementation. Only the four context
/// closures differ, and each of them is a stand-in rather than a shortcut: see `PreviewPlaceholder`.
///
/// Tokens naming nothing are left on screen exactly as the renderer leaves them, and a value that
/// could not be produced shows as the renderer's own `⚠︎`. The preview's job is to be the expansion,
/// including where it goes wrong.
struct SnippetPreviewView: View {
    let snippet: Snippet
    let globals: [GlobalVariable]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if snippet.content.isEmpty {
                Text("Nothing to preview yet. The content is empty.")
                    .foregroundStyle(.secondary)
            } else {
                Text(rendered)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("""
                Shell commands and the clipboard aren't read while you're editing. Questions show \
                their text, and \(PreviewPlaceholder.caret) is where the caret ends up.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var rendered: String {
        switch ExpansionRenderer().render(snippet: snippet, transform: .none, context: context) {
        case .rendered(let expansion):
            return Self.marking(expansion)
        case .needsForm(let variable, _):
            // Unreachable while `formAnswers` answers every field of every form, and cheap to keep
            // honest if that ever stops being true.
            return String(localized: """
                \u{201C}\(variable.name)\u{201D} needs a few answers.
                """)
        }
    }

    /// The preview's world.
    ///
    /// `pickRandom` takes the first option rather than a random one: the preview re-renders on every
    /// keystroke, and a choice variable that rolled again each time would flicker while you typed
    /// around it. `now` is read live, so a date variable is right whenever you look at it.
    private var context: RenderContext {
        RenderContext(
            now: { Date() },
            clipboard: { PreviewPlaceholder.clipboard },
            runShell: { _, _ in PreviewPlaceholder.shell },
            pickRandom: { $0.first ?? "" },
            globals: globals,
            formAnswers: formAnswers)
    }

    /// Every form field answered with its own label, so a form snippet previews as the shape of what
    /// it will produce instead of stopping at the form gate.
    private var formAnswers: [String: String] {
        var answers: [String: String] = [:]
        for variable in snippet.variables {
            for field in fields(of: variable) {
                answers["\(variable.name).\(field.name)"] = field.label.isEmpty
                    ? field.name : field.label
            }
        }
        return answers
    }

    /// The fields a variable asks for, following one hop through a global — keyed under the *local*
    /// name, which is the name the content's tokens spell and the name the renderer looks answers up
    /// under.
    private func fields(of variable: Variable) -> [FormField] {
        switch variable.kind {
        case .form(let fields):
            return fields
        case .global(let target):
            guard let global = globals.first(where: { $0.variable.name == target }),
                  case .form(let fields) = global.variable.kind else { return [] }
            return fields
        default:
            return []
        }
    }

    /// The rendered text with the caret marker put back in where `$|$` asked for it.
    ///
    /// `cursorOffsetFromEnd` counts `Character`s, which is what the offset is measured in, so this
    /// steps back through the string rather than indexing into it.
    private static func marking(_ expansion: RenderedExpansion) -> String {
        guard let offset = expansion.cursorOffsetFromEnd, offset >= 0,
              offset <= expansion.text.count else { return expansion.text }
        var text = expansion.text
        text.insert(contentsOf: PreviewPlaceholder.caret,
                    at: text.index(text.endIndex, offsetBy: -offset))
        return text
    }
}
