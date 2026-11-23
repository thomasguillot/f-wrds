import Foundation
import Testing
import WrdsKit

/// Runs `body` against a freshly created, empty directory that is removed afterwards.
private func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("AppSettingsTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try body(directory)
}

/// Reads a written file back as raw JSON, so tests assert on the on-disk shape rather than on a
/// round-trip through the same encoder that produced it.
private func jsonObject(at url: URL) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    return try #require(object as? [String: Any], "expected a JSON object at \(url.lastPathComponent)")
}

/// ⌥Space: Carbon virtual key code 49, Carbon `optionKey` mask.
private let optionSpace = HotKeySpec(keyCode: 49, modifiers: 0x0800)

@Suite("AppSettings")
struct AppSettingsTests {

    @Test("The default settings are the ones the app ships with")
    func defaultsAreAsSpecified() {
        let settings = AppSettings.default

        #expect(settings.engineEnabled)
        #expect(settings.undoOnBackspace)
        #expect(settings.pickerHotKey == optionSpace)
        #expect(settings.pauseHotKey == nil)
        #expect(settings.defaultInjectionMode == .paste)
        #expect(settings.perAppInjectionOverrides.isEmpty)
        #expect(settings.showDockIcon == false)
        #expect(settings.launchAtLogin == false)
        #expect(settings.openWindowAtLaunch)
        #expect(settings.languageOverride == nil)
        #expect(settings.checkForUpdatesAutomatically)
        #expect(settings.pinnedSnippetIDs.isEmpty)
    }

    @Test("Injection modes keep their on-disk spellings")
    func injectionModeRawValues() {
        #expect(AppSettings.InjectionMode.paste.rawValue == "paste")
        #expect(AppSettings.InjectionMode.typed.rawValue == "typed")
    }
}

@Suite("SettingsStore")
struct SettingsStoreTests {

    private static func settingsURL(_ directory: URL) -> URL {
        directory.appendingPathComponent("settings.json", isDirectory: false)
    }

    private static func corruptURL(_ directory: URL) -> URL {
        directory.appendingPathComponent("settings.json.corrupt", isDirectory: false)
    }

    /// Every field moved off its default, so a round-trip that drops one is caught.
    private static func fullyPopulatedSettings() -> AppSettings {
        var settings = AppSettings.default
        settings.engineEnabled = false
        settings.undoOnBackspace = false
        settings.pickerHotKey = HotKeySpec(keyCode: 36, modifiers: 0x0100)
        settings.pauseHotKey = HotKeySpec(keyCode: 53, modifiers: 0x1000)
        settings.defaultInjectionMode = .typed
        settings.perAppInjectionOverrides = ["com.apple.Terminal": .typed, "com.apple.Safari": .paste]
        settings.showDockIcon = true
        settings.launchAtLogin = true
        settings.openWindowAtLaunch = false
        settings.languageOverride = "en-GB"
        settings.checkForUpdatesAutomatically = false
        settings.pinnedSnippetIDs = [UUID(), UUID()]
        return settings
    }

    // MARK: Round-trip

    @Test("Every settings field survives an update and a load by a separate store")
    func roundTripsThroughDisk() throws {
        try withTemporaryDirectory { directory in
            let settings = Self.fullyPopulatedSettings()

            let store = SettingsStore(directory: directory)
            try store.load()
            try store.update(settings)

            let reloaded = SettingsStore(directory: directory)
            try reloaded.load()

            #expect(reloaded.settings == settings)
            #expect(reloaded.settings.perAppInjectionOverrides["com.apple.Terminal"] == .typed)
            #expect(reloaded.settings.pinnedSnippetIDs == settings.pinnedSnippetIDs)
            #expect(reloaded.settings.pauseHotKey == HotKeySpec(keyCode: 53, modifiers: 0x1000))
            #expect(reloaded.didPreserveCorruptFile == false)
        }
    }

    @Test("A written settings file carries the version alongside the settings payload")
    func writesVersionedEnvelope() throws {
        try withTemporaryDirectory { directory in
            let store = SettingsStore(directory: directory)
            try store.load()
            try store.update(Self.fullyPopulatedSettings())

            let object = try jsonObject(at: Self.settingsURL(directory))

            #expect(object["version"] as? Int == 1)
            let payload = try #require(object["settings"] as? [String: Any])
            #expect(payload["defaultInjectionMode"] as? String == "typed")
            #expect(payload["languageOverride"] as? String == "en-GB")
        }
    }

    // MARK: Defaults

    @Test("Loading with no file on disk yields the defaults and writes them out")
    func defaultsWhenFileIsMissing() throws {
        try withTemporaryDirectory { directory in
            let store = SettingsStore(directory: directory)

            try store.load()

            #expect(store.settings == AppSettings.default)
            #expect(store.didPreserveCorruptFile == false)
            let object = try jsonObject(at: Self.settingsURL(directory))
            #expect(object["version"] as? Int == 1)
        }
    }

    @Test("A settings file missing keys keeps the defaults for them instead of resetting the file")
    func missingKeysFallBackToDefaults() throws {
        try withTemporaryDirectory { directory in
            let partial = Data(#"{"version":1,"settings":{"showDockIcon":true}}"#.utf8)
            try partial.write(to: Self.settingsURL(directory))

            let store = SettingsStore(directory: directory)
            try store.load()

            #expect(store.settings.showDockIcon)
            #expect(store.settings.engineEnabled, "an absent key must not flip a default")
            #expect(store.settings.checkForUpdatesAutomatically)
            #expect(store.settings.defaultInjectionMode == .paste)
            #expect(store.settings.pinnedSnippetIDs.isEmpty)
            // Optionals are the exception to that leniency: absence reads as "cleared", because
            // omitting the key is exactly how clearing a hot key is persisted.
            #expect(store.settings.pickerHotKey == nil)
            #expect(store.didPreserveCorruptFile == false)
            #expect(FileManager.default.fileExists(atPath: Self.corruptURL(directory).path) == false)
        }
    }

    @Test("A hot key the user cleared stays cleared across a reload")
    func clearedHotKeyIsNotResurrected() throws {
        try withTemporaryDirectory { directory in
            var settings = AppSettings.default
            settings.pickerHotKey = nil

            let store = SettingsStore(directory: directory)
            try store.load()
            try store.update(settings)

            // Encoding omits a nil optional, so absence is how "cleared" is stored; loading must
            // read it back as cleared rather than restoring the ⌥Space default.
            let object = try jsonObject(at: Self.settingsURL(directory))
            let payload = try #require(object["settings"] as? [String: Any])
            #expect(payload["pickerHotKey"] == nil)

            let reloaded = SettingsStore(directory: directory)
            try reloaded.load()
            #expect(reloaded.settings.pickerHotKey == nil)
        }
    }

    // MARK: Corruption

    @Test("Undecodable bytes are copied to settings.json.corrupt before the defaults replace them")
    func preservesCorruptBytesAndFallsBackToDefaults() throws {
        try withTemporaryDirectory { directory in
            let garbage = Data("not settings at all ⚠️".utf8)
            try garbage.write(to: Self.settingsURL(directory))

            let store = SettingsStore(directory: directory)
            try store.load()

            let preserved = try Data(contentsOf: Self.corruptURL(directory))
            #expect(preserved == garbage, "the original bytes must survive byte-for-byte")
            #expect(store.didPreserveCorruptFile)
            #expect(store.settings == AppSettings.default)
        }
    }

    @Test("An envelope without a settings payload is corruption, not a missing key")
    func envelopeWithoutPayloadIsCorruption() throws {
        try withTemporaryDirectory { directory in
            let headerOnly = Data(#"{"version":1}"#.utf8)
            try headerOnly.write(to: Self.settingsURL(directory))

            let store = SettingsStore(directory: directory)
            try store.load()

            let preserved = try Data(contentsOf: Self.corruptURL(directory))
            #expect(preserved == headerOnly)
            #expect(store.didPreserveCorruptFile)
            #expect(store.settings == AppSettings.default)
        }
    }

    // MARK: Versioning

    @Test("Settings from a newer schema version throw and are left untouched")
    func unsupportedVersionThrowsWithoutTouchingTheFile() throws {
        try withTemporaryDirectory { directory in
            let fileURL = Self.settingsURL(directory)
            let future = Data(#"{"version":99,"settings":{}}"#.utf8)
            try future.write(to: fileURL)

            let store = SettingsStore(directory: directory)

            #expect(throws: StoreError.unsupportedVersion(99)) { try store.load() }
            let onDisk = try Data(contentsOf: fileURL)
            #expect(onDisk == future)
            #expect(FileManager.default.fileExists(atPath: Self.corruptURL(directory).path) == false)
        }
    }

    // MARK: Writes require a successful load

    @Test("Settings whose load failed refuse to write over the file they could not read")
    func updatesAreRefusedAfterAFailedLoad() throws {
        try withTemporaryDirectory { directory in
            let fileURL = Self.settingsURL(directory)
            let future = Data(#"{"version":99,"settings":{}}"#.utf8)
            try future.write(to: fileURL)

            let store = SettingsStore(directory: directory)
            #expect(throws: StoreError.unsupportedVersion(99)) { try store.load() }
            #expect(store.hasLoadedSuccessfully == false)

            // Toggling any preference after the error must not stamp the defaults over the file.
            var settings = AppSettings.default
            settings.showDockIcon = true
            #expect(throws: StoreError.notLoaded) { try store.update(settings) }
            let onDisk = try Data(contentsOf: fileURL)
            #expect(onDisk == future)
            #expect(FileManager.default.fileExists(atPath: Self.corruptURL(directory).path) == false)
        }
    }

    @Test("A settings store that never loaded refuses to write, file or no file")
    func updatesAreRefusedBeforeAnyLoad() throws {
        try withTemporaryDirectory { directory in
            let existing = Data(#"{"version":1,"settings":{"showDockIcon":true}}"#.utf8)
            try existing.write(to: Self.settingsURL(directory))

            let store = SettingsStore(directory: directory)

            #expect(throws: StoreError.notLoaded) { try store.update(.default) }
            let onDisk = try Data(contentsOf: Self.settingsURL(directory))
            #expect(onDisk == existing)
        }

        try withTemporaryDirectory { directory in
            let store = SettingsStore(directory: directory)

            #expect(throws: StoreError.notLoaded) { try store.update(.default) }
            #expect(FileManager.default.fileExists(atPath: Self.settingsURL(directory).path) == false)
        }
    }

    // MARK: Directory

    @Test("The settings directory is created when it does not exist yet")
    func initCreatesMissingDirectory() throws {
        try withTemporaryDirectory { directory in
            let nested = directory.appendingPathComponent("FWrds", isDirectory: true)

            _ = SettingsStore(directory: nested)

            #expect(FileManager.default.fileExists(atPath: nested.path))
        }
    }
}
