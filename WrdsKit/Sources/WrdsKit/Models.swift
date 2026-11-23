import Foundation

/// How a matched trigger's casing is propagated onto the rendered expansion.
public enum UppercaseStyle: String, Codable, Sendable, CaseIterable {
    /// First character of the expansion uppercased.
    case capitalise
    /// First character of each word uppercased.
    case capitaliseWords
    /// Whole expansion uppercased.
    case uppercase
}

/// One field of a form variable, filled in by the form panel before injection.
public struct FormField: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: Codable, Equatable, Sendable {
        case text(default: String)
        case multiline(default: String)
        case choice(options: [String])

        // Hand-written Codable: a `type` discriminator keeps the on-disk JSON stable and
        // human-readable rather than exposing Swift's synthesised enum encoding.
        private enum CodingKeys: String, CodingKey {
            case type
            case `default`
            case options
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "text":
                self = .text(default: try container.decode(String.self, forKey: .default))
            case "multiline":
                self = .multiline(default: try container.decode(String.self, forKey: .default))
            case "choice":
                self = .choice(options: try container.decode([String].self, forKey: .options))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type, in: container,
                    debugDescription: "Unknown FormField.Kind type '\(type)'")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let defaultValue):
                try container.encode("text", forKey: .type)
                try container.encode(defaultValue, forKey: .default)
            case .multiline(let defaultValue):
                try container.encode("multiline", forKey: .type)
                try container.encode(defaultValue, forKey: .default)
            case .choice(let options):
                try container.encode("choice", forKey: .type)
                try container.encode(options, forKey: .options)
            }
        }
    }

    public var id: UUID
    /// Referenced in snippet content as `{{form.<name>}}`.
    public var name: String
    /// Shown next to the field in the form panel.
    public var label: String
    public var kind: Kind

    public init(id: UUID = UUID(), name: String, label: String, kind: Kind) {
        self.id = id
        self.name = name
        self.label = label
        self.kind = kind
    }
}

/// A value resolved at expansion time and substituted into a snippet's content.
///
/// This enum is the Espanso parity backbone: import, export, rendering, and the editor UI
/// all switch over `Variable.Kind`.
public struct Variable: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: Codable, Equatable, Sendable {
        /// strftime-style format (e.g. `"%Y-%m-%d"`), shifted by `offsetSeconds` from now.
        case date(format: String, offsetSeconds: Int)
        case clipboard
        /// Random pick from `options`.
        case choice(options: [String])
        case echo(value: String)
        case shell(command: String, timeoutSeconds: Double)
        case form(fields: [FormField])
        /// Reference to a `GlobalVariable` by name.
        case global(name: String)

        // Hand-written Codable: a `type` discriminator keeps the on-disk JSON stable and
        // human-readable rather than exposing Swift's synthesised enum encoding.
        private enum CodingKeys: String, CodingKey {
            case type
            case format
            case offsetSeconds
            case options
            case value
            case command
            case timeoutSeconds
            case fields
            case name
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "date":
                self = .date(format: try container.decode(String.self, forKey: .format),
                             offsetSeconds: try container.decode(Int.self, forKey: .offsetSeconds))
            case "clipboard":
                self = .clipboard
            case "choice":
                self = .choice(options: try container.decode([String].self, forKey: .options))
            case "echo":
                self = .echo(value: try container.decode(String.self, forKey: .value))
            case "shell":
                self = .shell(
                    command: try container.decode(String.self, forKey: .command),
                    timeoutSeconds: Self.clampedShellTimeout(
                        try container.decode(Double.self, forKey: .timeoutSeconds)))
            case "form":
                self = .form(fields: try container.decode([FormField].self, forKey: .fields))
            case "global":
                self = .global(name: try container.decode(String.self, forKey: .name))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type, in: container,
                    debugDescription: "Unknown Variable.Kind type '\(type)'")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .date(let format, let offsetSeconds):
                try container.encode("date", forKey: .type)
                try container.encode(format, forKey: .format)
                try container.encode(offsetSeconds, forKey: .offsetSeconds)
            case .clipboard:
                try container.encode("clipboard", forKey: .type)
            case .choice(let options):
                try container.encode("choice", forKey: .type)
                try container.encode(options, forKey: .options)
            case .echo(let value):
                try container.encode("echo", forKey: .type)
                try container.encode(value, forKey: .value)
            case .shell(let command, let timeoutSeconds):
                try container.encode("shell", forKey: .type)
                try container.encode(command, forKey: .command)
                try container.encode(timeoutSeconds, forKey: .timeoutSeconds)
            case .form(let fields):
                try container.encode("form", forKey: .type)
                try container.encode(fields, forKey: .fields)
            case .global(let name):
                try container.encode("global", forKey: .type)
                try container.encode(name, forKey: .name)
            }
        }

        /// The budget a shell variable falls back to when the file says nothing usable — the same ten
        /// seconds an Espanso import invents, for the same reasons (`EspansoImporter`).
        static let defaultShellTimeoutSeconds = 10.0

        /// The longest budget a stored shell timeout may ask for. An hour is far past anything a
        /// snippet — a paste into a document — could honestly need, and is chosen to be a number a
        /// person would recognise as a ceiling rather than the largest one the arithmetic allows.
        static let maximumShellTimeoutSeconds = 3600.0

        /// `seconds`, brought back inside what a shell variable is allowed to ask for.
        ///
        /// Validated **on decode**, because this is the one field of the model where a value nobody
        /// typed can stop the whole app. `store.json` is a file on disk: a hand edit, a merge, a
        /// restored backup from a build that wrote it differently, or plain corruption can put
        /// `1e10` in here. `ShellRunner` reads anything past a century as "no deadline at all" and
        /// waits on `.distantFuture` — on `ExpansionEngine`'s one serial queue, which every
        /// expansion and every keystroke behind it is confined to. One such variable would wedge
        /// expansion permanently, with no error, no UI and nothing to restart short of the app.
        ///
        /// Non-finite or non-positive falls back rather than clamping to the nearest end: `NaN` and
        /// `-5` are not somebody asking for a very short timeout, they are the file failing to say
        /// anything, and the honest reading of that is the default.
        static func clampedShellTimeout(_ seconds: Double) -> Double {
            guard seconds.isFinite, seconds > 0 else { return defaultShellTimeoutSeconds }
            return min(seconds, maximumShellTimeoutSeconds)
        }
    }

    public var id: UUID
    /// Referenced in snippet content as `{{<name>}}`.
    public var name: String
    public var kind: Kind

    public init(id: UUID = UUID(), name: String, kind: Kind) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}

/// A single expansion: what to match, what to type back, and how.
public struct Snippet: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// Literal triggers. Empty iff `regexTrigger` is set.
    public var triggers: [String]
    public var regexTrigger: String?
    public var label: String
    /// May contain `{{var}}` tokens and the `$|$` cursor marker.
    public var content: String
    /// Fire only after a word delimiter (Espanso `word:`).
    public var wordBoundary: Bool
    public var propagateCase: Bool
    public var uppercaseStyle: UppercaseStyle?
    public var variables: [Variable]
    public var isEnabled: Bool
    /// Raw YAML fragments of unrecognised Espanso keys, kept verbatim for lossless re-export.
    public var unmapped: [String: String]

    public init(id: UUID = UUID(), triggers: [String] = [], regexTrigger: String? = nil,
                label: String = "", content: String = "", wordBoundary: Bool = false,
                propagateCase: Bool = false, uppercaseStyle: UppercaseStyle? = nil,
                variables: [Variable] = [], isEnabled: Bool = true,
                unmapped: [String: String] = [:]) {
        self.id = id
        self.triggers = triggers
        self.regexTrigger = regexTrigger
        self.label = label
        self.content = content
        self.wordBoundary = wordBoundary
        self.propagateCase = propagateCase
        self.uppercaseStyle = uppercaseStyle
        self.variables = variables
        self.isEnabled = isEnabled
        self.unmapped = unmapped
    }
}

/// A named, ordered collection of snippets — the sidebar unit, and the Espanso match-file unit.
public struct SnippetGroup: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var snippets: [Snippet]
    /// Bundle IDs the group is limited to. Empty means everywhere.
    public var onlyInApps: [String]
    /// Bundle IDs the group is suppressed in.
    public var neverInApps: [String]
    public var isEnabled: Bool

    public init(id: UUID = UUID(), name: String, snippets: [Snippet] = [],
                onlyInApps: [String] = [], neverInApps: [String] = [], isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.snippets = snippets
        self.onlyInApps = onlyInApps
        self.neverInApps = neverInApps
        self.isEnabled = isEnabled
    }
}

/// A variable shared across snippets, referenced by `Variable.Kind.global(name:)`.
///
/// A `.global` kind is invalid as the wrapped variable: globals do not chain to other globals.
public struct GlobalVariable: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var variable: Variable

    public init(id: UUID = UUID(), variable: Variable) {
        self.id = id
        self.variable = variable
    }
}
