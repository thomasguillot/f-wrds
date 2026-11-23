import Foundation

/// A global hot key, stored the way Carbon's `RegisterEventHotKey` wants it.
public struct HotKeySpec: Codable, Equatable, Sendable {
    /// Carbon virtual key code (49 is Space).
    public var keyCode: UInt32
    /// Carbon modifier mask (`optionKey` is `0x0800`).
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

/// Everything the user can configure, persisted as `settings.json`.
public struct AppSettings: Codable, Equatable, Sendable {
    /// How a rendered expansion reaches the frontmost app.
    public enum InjectionMode: String, Codable, Sendable {
        /// Put the expansion on the pasteboard and send ⌘V — fast and exact.
        case paste
        /// Synthesise the keystrokes — slower, but works where paste is blocked.
        case typed
    }

    public var engineEnabled: Bool = true
    public var undoOnBackspace: Bool = true
    /// ⌥Space: Carbon virtual key code 49 with the Carbon `optionKey` mask.
    public var pickerHotKey: HotKeySpec? = HotKeySpec(keyCode: 49, modifiers: 0x0800)
    public var pauseHotKey: HotKeySpec?
    public var defaultInjectionMode: InjectionMode = .paste
    /// Bundle ID → the mode to use in that app, overriding `defaultInjectionMode`.
    public var perAppInjectionOverrides: [String: InjectionMode] = [:]
    public var showDockIcon: Bool = false
    public var launchAtLogin: Bool = false
    /// Whether the manager window opens when the app starts.
    public var openWindowAtLaunch: Bool = true
    /// `nil` follows the system language; otherwise `"en-GB"`, `"en"`, or `"fr"`.
    public var languageOverride: String?
    public var checkForUpdatesAutomatically: Bool = true
    /// Snippets pinned to the top of the menu bar menu, in the order shown there.
    public var pinnedSnippetIDs: [UUID] = []

    /// The settings a fresh install starts with, and the only way to obtain an `AppSettings` from
    /// outside the module: settings are always derived from the defaults and then adjusted, never
    /// assembled field by field.
    public static let `default` = AppSettings()
}

extension AppSettings {
    /// Decoded leniently: a missing key keeps its default instead of failing the whole file.
    ///
    /// Settings are independent toggles, so "the user never set this one" has an obvious and safe
    /// answer, and a build that adds a toggle must not reset every other preference on first launch.
    /// Snippets get the opposite treatment — there is no safe default for a snippet's missing
    /// content, so `store.json` fails closed and preserves the bytes instead.
    ///
    /// The optional fields are the exception: encoding omits a `nil` optional, so an absent
    /// `pickerHotKey` is how "the user cleared this hot key" is stored. Defaulting it back to
    /// ⌥Space on load would resurrect a shortcut the user deliberately removed. The cost is that
    /// absence cannot also mean "never written": a hand-edited or truncated file that drops an
    /// optional reads as cleared rather than as its default, which is the right trade only because
    /// clearing a hot key is a real flow and hand-editing this file is not.
    ///
    /// Declared in an extension so the memberwise initialiser that supplies those defaults survives.
    public init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        engineEnabled = try container.decodeIfPresent(Bool.self, forKey: .engineEnabled) ?? engineEnabled
        undoOnBackspace =
            try container.decodeIfPresent(Bool.self, forKey: .undoOnBackspace) ?? undoOnBackspace
        pickerHotKey = try container.decodeIfPresent(HotKeySpec.self, forKey: .pickerHotKey)
        pauseHotKey = try container.decodeIfPresent(HotKeySpec.self, forKey: .pauseHotKey)
        defaultInjectionMode =
            try container.decodeIfPresent(InjectionMode.self, forKey: .defaultInjectionMode)
            ?? defaultInjectionMode
        perAppInjectionOverrides =
            try container.decodeIfPresent([String: InjectionMode].self, forKey: .perAppInjectionOverrides)
            ?? perAppInjectionOverrides
        showDockIcon = try container.decodeIfPresent(Bool.self, forKey: .showDockIcon) ?? showDockIcon
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? launchAtLogin
        openWindowAtLaunch =
            try container.decodeIfPresent(Bool.self, forKey: .openWindowAtLaunch) ?? openWindowAtLaunch
        languageOverride = try container.decodeIfPresent(String.self, forKey: .languageOverride)
        checkForUpdatesAutomatically =
            try container.decodeIfPresent(Bool.self, forKey: .checkForUpdatesAutomatically)
            ?? checkForUpdatesAutomatically
        pinnedSnippetIDs =
            try container.decodeIfPresent([UUID].self, forKey: .pinnedSnippetIDs) ?? pinnedSnippetIDs
    }
}

/// The `settings.json` envelope: the schema version plus the settings it applies to.
private struct SettingsPayload: Codable {
    var version: Int
    var settings: AppSettings
}

/// Reads and writes `settings.json`.
///
/// Fail-closed in the same way as `SnippetStore`: a file that cannot be decoded is copied to
/// `settings.json.corrupt` before the defaults replace it, and nothing is written until a `load()`
/// has succeeded.
public final class SettingsStore {
    private let directory: URL

    public private(set) var settings: AppSettings = .default

    /// True when the last `load()` found bytes it could not decode and copied them to
    /// `settings.json.corrupt` before falling back to the defaults.
    public private(set) var didPreserveCorruptFile = false

    /// True only between a completed `load()` and the next `load()` attempt. `update(_:)` is gated
    /// on it: until this store has read the file, its in-memory defaults are an assumption rather
    /// than the user's actual settings, and writing them out would discard the real ones.
    public private(set) var hasLoadedSuccessfully = false

    private var fileURL: URL { directory.appendingPathComponent("settings.json", isDirectory: false) }

    public init(directory: URL) {
        self.directory = directory
        // Best effort: this initialiser cannot throw, so a directory that genuinely cannot be
        // created surfaces from `load()`/`update(_:)`, which re-create it and can report the failure.
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Loads `settings.json`, falling back to the defaults when there is nothing usable to load.
    ///
    /// Must succeed before `update(_:)` is allowed. A load that throws clears
    /// `hasLoadedSuccessfully`, so a caller that reports the error and carries on cannot then
    /// overwrite the file this refused to touch.
    public func load() throws {
        didPreserveCorruptFile = false
        hasLoadedSuccessfully = false
        switch try StoreFile.read(SettingsPayload.self, from: fileURL) {
        case .payload(let payload):
            // A file that decoded is left exactly as it is on disk; loading never rewrites it.
            settings = payload.settings
        case .missing:
            try adoptDefaults()
        case .corruptPreserved:
            didPreserveCorruptFile = true
            try adoptDefaults()
        }
        hasLoadedSuccessfully = true
    }

    /// Persists `settings` and adopts them.
    ///
    /// - Throws: `StoreError.notLoaded` if no `load()` has succeeded yet.
    public func update(_ settings: AppSettings) throws {
        guard hasLoadedSuccessfully else { throw StoreError.notLoaded }
        // Disk first: in-memory state only advances once the bytes are written, so a failed write
        // leaves the store reporting what is actually persisted.
        try write(settings)
        self.settings = settings
    }

    /// Writes the defaults and adopts them. Used only from `load()`, which is why it bypasses the
    /// gate that guards `update(_:)`.
    private func adoptDefaults() throws {
        try write(.default)
        settings = .default
    }

    private func write(_ settings: AppSettings) throws {
        try StoreFile.write(SettingsPayload(version: StoreFile.version, settings: settings), to: fileURL)
    }
}
