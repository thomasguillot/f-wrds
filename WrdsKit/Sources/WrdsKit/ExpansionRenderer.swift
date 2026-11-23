import Foundation

/// Everything the renderer needs from outside itself.
///
/// The four closures are the whole of the renderer's contact with the world, which is what keeps
/// WrdsKit free of AppKit and the tests free of a clock, a pasteboard and a subprocess. The
/// defaults are the *safe* production shape rather than the complete one: the app layer replaces
/// `clipboard` with a pasteboard read and `runShell` with the real runner at startup.
public struct RenderContext: Sendable {
    /// The clock. Read at most once per render, so a snippet holding both a date and a time cannot
    /// straddle a second boundary.
    public var now: @Sendable () -> Date
    /// The clipboard's text, or `nil` when it holds nothing rendering can use — an image, say.
    /// Defaults to `nil` because reading the pasteboard means AppKit; the app injects the real read.
    public var clipboard: @Sendable () -> String?
    /// Runs `command` and returns its output, or throws — including on timeout. The default throws
    /// unconditionally: a renderer nobody wired a shell into must not silently render nothing where
    /// a command's output belonged.
    public var runShell: @Sendable (_ command: String, _ timeoutSeconds: Double) throws -> String
    /// Picks one of `options`. Injected rather than called inline so tests are deterministic.
    /// Never called with an empty list.
    public var pickRandom: @Sendable (_ options: [String]) -> String
    /// The library's shared variables, resolved by name after the snippet's own.
    public var globals: [GlobalVariable]
    /// Named captures from the regex trigger that fired, resolved after globals.
    public var regexCaptures: [String: String]
    /// Form answers, keyed `"<variableName>.<fieldName>"` — the same spelling as the token that
    /// reads them.
    public var formAnswers: [String: String]
    /// Names and AM/PM symbols in date variables. Injected so tests can pin them.
    public var locale: Locale
    /// The zone date variables are read in, which is what decides what "today" is.
    public var timeZone: TimeZone

    public init(
        now: @escaping @Sendable () -> Date = { Date() },
        clipboard: @escaping @Sendable () -> String? = { nil },
        runShell: @escaping @Sendable (String, Double) throws -> String = { _, _ in
            throw CocoaError(.featureUnsupported, userInfo: [
                NSLocalizedDescriptionKey: "No shell runner was injected into this RenderContext."
            ])
        },
        pickRandom: @escaping @Sendable ([String]) -> String = { $0.randomElement() ?? "" },
        globals: [GlobalVariable] = [],
        regexCaptures: [String: String] = [:],
        formAnswers: [String: String] = [:],
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) {
        self.now = now
        self.clipboard = clipboard
        self.runShell = runShell
        self.pickRandom = pickRandom
        self.globals = globals
        self.regexCaptures = regexCaptures
        self.formAnswers = formAnswers
        self.locale = locale
        self.timeZone = timeZone
    }
}

/// Text ready to inject, and where the caret should end up in it.
public struct RenderedExpansion: Equatable, Sendable {
    public var text: String
    /// How many characters left of the end of `text` the caret belongs, or `nil` if the snippet
    /// carried no `$|$`. Counted in `Character`s because the caller moves the caret with arrow
    /// keys, and one arrow press crosses one grapheme cluster.
    public var cursorOffsetFromEnd: Int?

    public init(text: String, cursorOffsetFromEnd: Int? = nil) {
        self.text = text
        self.cursorOffsetFromEnd = cursorOffsetFromEnd
    }
}

/// What a render produced: finished text, or a form that has to be filled in first.
public enum RenderResult: Equatable, Sendable {
    case rendered(RenderedExpansion)
    /// The first form variable with an unanswered field. `variable.name` is the prefix its answers
    /// are keyed under: answer it and render again with those answers in `formAnswers`.
    case needsForm(variable: Variable, fields: [FormField])
}

/// A value that could not be produced.
///
/// Internal signalling only — it never escapes `render`, which turns each of these into a `⚠︎`
/// where the token stood and carries on with the rest of the text. An expansion fires in whatever
/// app the user is typing in; failing half of one is recoverable, refusing all of it silently is
/// not.
public enum RenderError: Error, Equatable {
    /// The chain of variable names that closed the loop, outermost first.
    case cycleDetected([String])
    case shellFailed(variable: String)
}

/// Turns a matched snippet into the text to inject.
///
/// Three passes, in this order, and the order is the point:
///
/// 1. **The form gate.** If any form variable is unanswered the render stops before it starts. It
///    is going to be run again once the panel comes back, and a clipboard read or a shell command
///    that happened on this pass would happen twice.
/// 2. **Substitution.** Tokens are resolved lazily and memoised, so a variable is evaluated at most
///    once per expansion and never at all if nothing refers to it.
/// 3. **The cursor marker and the case transform**, on the substituted text — which is why typing
///    `:SIG` uppercases the date the snippet expanded to, not just the letters its author typed.
public struct ExpansionRenderer: Sendable {

    public init() {}

    public func render(snippet: Snippet, transform: CaseTransform,
                       context: RenderContext) -> RenderResult {
        if let pending = Self.pendingForm(in: snippet, context: context) {
            return .needsForm(variable: pending.variable, fields: pending.fields)
        }
        let substituted = Resolver(snippet: snippet, context: context).substitute(snippet.content)
        return .rendered(Self.finishing(substituted, transform: transform,
                                        style: snippet.uppercaseStyle))
    }

    // MARK: The form gate

    /// The first declared form variable that is missing an answer, with the fields to ask for.
    ///
    /// Declared, not referenced: a form variable the content never reads is an authoring mistake,
    /// and the cost of asking about it is one stray panel, where the cost of missing a form that
    /// *is* read — from inside an echo variable, say — would be a `⚠︎` in the user's document.
    ///
    /// An answer that is present but empty counts as answered. Leaving a field blank is a thing the
    /// user is allowed to do.
    private static func pendingForm(in snippet: Snippet, context: RenderContext)
        -> (variable: Variable, fields: [FormField])? {
        for variable in snippet.variables {
            guard let fields = formFields(of: variable, in: context) else { continue }
            let unanswered = fields.contains { context.formAnswers["\(variable.name).\($0.name)"] == nil }
            if unanswered { return (variable, fields) }
        }
        return nil
    }

    /// The fields `variable` needs filling in, or `nil` if it is not a form.
    ///
    /// A local variable pointing at a global that happens to be a form counts, keyed under the
    /// *local* name — the name its tokens spell.
    private static func formFields(of variable: Variable, in context: RenderContext) -> [FormField]? {
        switch variable.kind {
        case .form(let fields):
            return fields
        case .global(let target):
            guard let global = context.globals.first(where: { $0.variable.name == target }),
                  case .form(let fields) = global.variable.kind else { return nil }
            return fields
        default:
            return nil
        }
    }

    // MARK: The cursor marker and the case transform

    /// Where the caret goes, spelled in the content.
    private static let cursorMarker = "$|$"

    /// Strips the first cursor marker and applies the case transform to what is left.
    ///
    /// The two interact, which is why one function does both. The text is cut at the marker and
    /// each side is cased separately, with the second told what character precedes it: that way
    /// capitalising a snippet whose marker sits before its first letter still capitalises the
    /// letter, a marker in the middle of a word does not start a new one, and the offset is the
    /// transformed tail's own length rather than a guess about whether casing changed it.
    ///
    /// Only the first marker goes. There is one caret, and a second marker is an authoring mistake
    /// that says more about itself by staying visible.
    private static func finishing(_ text: String, transform: CaseTransform,
                                  style: UppercaseStyle?) -> RenderedExpansion {
        guard let marker = text.range(of: cursorMarker) else {
            return RenderedExpansion(
                text: cased(text[...], transform: transform, style: style, previous: nil))
        }
        let head = cased(text[..<marker.lowerBound], transform: transform, style: style, previous: nil)
        let tail = cased(text[marker.upperBound...], transform: transform, style: style,
                         previous: head.last)
        return RenderedExpansion(text: head + tail, cursorOffsetFromEnd: tail.count)
    }

    /// Applies the transform the matcher asked for to one run of the final text.
    ///
    /// `previous` is the character immediately before this run, or `nil` at the start of the text.
    ///
    /// `uppercaseStyle` refines `.capitalised` only: `.uppercased` means the user typed the trigger
    /// in full caps and wants all of it, which nothing overrides.
    private static func cased(_ text: Substring, transform: CaseTransform, style: UppercaseStyle?,
                              previous: Character?) -> String {
        switch transform {
        case .none:
            return String(text)
        case .uppercased:
            return text.uppercased()
        case .capitalised:
            switch style {
            case .uppercase:
                return text.uppercased()
            case .capitaliseWords:
                return capitalisingWords(text, previous: previous)
            case .capitalise, nil:
                guard previous == nil, let first = text.first else { return String(text) }
                return first.uppercased() + text.dropFirst()
            }
        }
    }

    /// Uppercases the first character of each whitespace-separated word, leaving the rest as
    /// authored. Splitting on whitespace rather than on "not a letter" is what keeps "it's" and
    /// "well-known" from growing capitals in the middle.
    private static func capitalisingWords(_ text: Substring, previous: Character?) -> String {
        var output = ""
        var preceding = previous
        for character in text {
            if preceding?.isWhitespace ?? true {
                output += character.uppercased()
            } else {
                output.append(character)
            }
            preceding = character
        }
        return output
    }
}

/// Substitutes `{{token}}`s for one render.
///
/// One instance per render, because the memo and the in-progress stack it carries are what make a
/// variable resolve once and a cycle terminate.
private final class Resolver {

    /// What a value that could not be produced leaves behind: U+26A0 plus the text variation
    /// selector, so it renders as a glyph rather than as an emoji in the middle of a sentence.
    static let warning = "⚠\u{FE0E}"

    /// `{{name}}` or `{{name.field}}`, tolerating spaces inside the braces. The name has to start
    /// with a letter or an underscore, so `{{}}` and a stray `{{1}}` are just text.
    ///
    /// Optional because a pattern is a runtime value: this one cannot fail to compile, and if it
    /// somehow did, leaving tokens unsubstituted beats refusing to expand anything ever again.
    static let tokenPattern = try? NSRegularExpression(
        pattern: #"\{\{\s*([A-Za-z_][\w-]*)(?:\.([A-Za-z_][\w-]*))?\s*\}\}"#)

    private let snippet: Snippet
    private let context: RenderContext

    /// Values already produced this render, keyed by the token that produced them. A variable is
    /// evaluated at most once: two `{{pick}}`s are one draw, and two `{{branch}}`s are one process.
    private var resolved: [String: String] = [:]

    /// The names being resolved right now, outermost first. A name that turns up in here again has
    /// closed a cycle.
    private var open: [String] = []

    /// The instant this expansion happened at, read on first use and then held: a snippet whose
    /// date and time are separate variables has to describe one moment, and a snippet with no date
    /// variable at all never asks for the clock.
    private lazy var now: Date = context.now()

    init(snippet: Snippet, context: RenderContext) {
        self.snippet = snippet
        self.context = context
    }

    /// Replaces every token in `text` with its value.
    ///
    /// Only ever called on text the snippet's author wrote — the content itself and echo values.
    /// The output is not re-scanned, so a `{{token}}` arriving in the clipboard, in a form answer
    /// or in a command's output stays literal text: outside data must not be able to reach into the
    /// snippet library.
    func substitute(_ text: String) -> String {
        guard let tokenPattern = Self.tokenPattern, text.contains("{{") else { return text }
        let matches = tokenPattern.matches(in: text, options: [],
                                           range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }

        var output = ""
        var cursor = text.startIndex
        for match in matches {
            guard let token = Range(match.range, in: text),
                  let name = Range(match.range(at: 1), in: text) else { continue }
            let field = Range(match.range(at: 2), in: text).map { String(text[$0]) }
            output += text[cursor..<token.lowerBound]
            do {
                // A name that resolves to nothing is the author's typo, and stays on screen exactly
                // as written: that is recoverable, and it says which variable was meant. A name that
                // resolves to a value that could not be produced is a ⚠︎.
                output += try value(for: String(text[name]), field: field) ?? String(text[token])
            } catch {
                output += Self.warning
            }
            cursor = token.upperBound
        }
        output += text[cursor...]
        return output
    }

    /// The value of one token, or `nil` if the name belongs to nothing.
    ///
    /// Resolution order is snippet variables, then globals, then regex captures — so a snippet can
    /// shadow a global, and neither can be shadowed by whatever a regex trigger happened to
    /// capture. Among a snippet's own variables the first declaration of a name wins.
    ///
    /// Resolution is lazy: a variable nothing refers to is never evaluated, so a stale shell
    /// variable in a snippet costs nothing to keep. What that trades away is evaluation in
    /// declaration order — two independent commands run in the order the content mentions them.
    private func value(for name: String, field: String?) throws -> String? {
        let key = field.map { "\(name).\($0)" } ?? name
        if let cached = resolved[key] { return cached }
        // Checked before evaluating rather than after, so the recursion below is bounded by the
        // number of distinct names however the library is tangled.
        guard !open.contains(name) else { throw RenderError.cycleDetected(open + [name]) }

        open.append(name)
        defer { open.removeLast() }

        let produced: String
        if let variable = snippet.variables.first(where: { $0.name == name }) {
            produced = try produce(variable.kind, name: name, field: field, isGlobal: false)
        } else if let global = context.globals.first(where: { $0.variable.name == name }) {
            produced = try produce(global.variable.kind, name: name, field: field, isGlobal: true)
        } else if field == nil, let capture = context.regexCaptures[name] {
            // A capture is one string; `{{num.part}}` asks it for something it does not have, and
            // falls through to being left on screen.
            produced = capture
        } else {
            return nil
        }
        resolved[key] = produced
        return produced
    }

    /// Produces one variable's value. `isGlobal` marks a value that came from the shared library,
    /// which is the one place a `.global` reference is not allowed.
    private func produce(_ kind: Variable.Kind, name: String, field: String?,
                         isGlobal: Bool) throws -> String {
        switch kind {
        case .date(let format, let offsetSeconds):
            let date = now.addingTimeInterval(Double(offsetSeconds))
            return StrftimeFormatter.format(format, date: date, locale: context.locale,
                                            timeZone: context.timeZone)
        case .clipboard:
            // Nothing on the clipboard means nothing to paste, not a failure: the user asked for
            // whatever is there, and a ⚠︎ mid-sentence would be the louder mistake.
            return context.clipboard() ?? ""
        case .choice(let options):
            guard !options.isEmpty else { return Self.warning }
            return context.pickRandom(options)
        case .echo(let value):
            // The one kind whose value is template rather than data, and so the one kind that
            // recurses — which makes it also the only way to build a cycle out of local variables.
            return substitute(value)
        case .shell(let command, let timeoutSeconds):
            do {
                return Self.trimmingTrailingNewlines(try context.runShell(command, timeoutSeconds))
            } catch {
                throw RenderError.shellFailed(variable: name)
            }
        case .form:
            // `{{sign}}` on a form has no meaning — a form is several values — and an answer that
            // is missing here was never asked for by the gate, so the field name is wrong.
            guard let field, let answer = context.formAnswers["\(name).\(field)"] else {
                return Self.warning
            }
            return answer
        case .global(let target):
            // Globals are values, not aliases: one hop only. A missing target is a broken library
            // reference rather than a typo in the content, so it is worth a ⚠︎.
            guard !isGlobal,
                  let global = context.globals.first(where: { $0.variable.name == target })
            else { return Self.warning }
            // Still `name`, not `target`: the name the token spells is the name a form's answers
            // are keyed under, and the one worth naming if a command fails.
            return try produce(global.variable.kind, name: name, field: field, isGlobal: true)
        }
    }

    /// Drops the newline a command ends its output with — nearly all of them do, and it is a
    /// property of the terminal rather than of the value. Leading whitespace is left alone, since
    /// indentation can be exactly what the snippet wanted.
    private static func trimmingTrailingNewlines(_ output: String) -> String {
        var trimmed = Substring(output)
        while let last = trimmed.last, last == "\n" || last == "\r" { trimmed.removeLast() }
        return String(trimmed)
    }
}
