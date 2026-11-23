import Foundation

/// Failures the persistence layer refuses to resolve on its own.
public enum StoreError: Error, Equatable, Sendable {
    /// The file carries a schema version this build does not understand — in practice, a store
    /// written by a newer F Wrds. The file is left exactly as it is so that newer build can still
    /// read it; callers report this rather than starting fresh over data they cannot interpret.
    case unsupportedVersion(Int)

    /// A write was attempted before a `load()` had succeeded. Writing then would stamp this build's
    /// empty in-memory state over a file that was never read — including the very file a failed
    /// `load()` deliberately refused to touch — so every write requires a successful load first.
    case notLoaded
}

/// The JSON file mechanics shared by `SnippetStore` and `SettingsStore`.
///
/// Both stores read a versioned envelope, preserve bytes they cannot decode before anything
/// overwrites them, and write atomically. Keeping that in one place is what makes the fail-closed
/// guarantee identical for `store.json` and `settings.json`.
enum StoreFile {
    /// Schema version stamped into every file this build writes.
    static let version = 1

    /// What `read(_:from:)` found on disk.
    enum Outcome<Payload> {
        /// A payload decoded from a file at the current schema version.
        case payload(Payload)
        /// Nothing at that path yet — the caller starts fresh.
        case missing
        /// Bytes that could not be decoded. They are already copied to `<name>.corrupt`, so the
        /// caller is free to start fresh.
        case corruptPreserved
    }

    /// Reads and decodes `url`, preserving anything it cannot decode.
    ///
    /// The envelope's `version` is decoded on its own, ahead of the payload, so a future build can
    /// branch on it and migrate instead of mistaking a newer schema for corruption.
    ///
    /// - Throws: `StoreError.unsupportedVersion` for a readable file from another schema version
    ///   (leaving the file untouched); a read error when an existing file cannot be read, which is
    ///   never quietly downgraded to "no file"; a write error when the `.corrupt` copy fails, so a
    ///   caller never starts fresh over bytes that were not preserved.
    static func read<Payload: Decodable>(_ type: Payload.Type, from url: URL) throws -> Outcome<Payload> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        let data = try Data(contentsOf: url)
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            try preserveCorrupt(data, of: url)
            return .corruptPreserved
        }
        guard envelope.version == version else {
            throw StoreError.unsupportedVersion(envelope.version)
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            try preserveCorrupt(data, of: url)
            return .corruptPreserved
        }
        return .payload(payload)
    }

    /// Atomically writes `payload`, re-creating the containing directory if it has gone missing.
    static func write(_ payload: some Encodable, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        // Sorted keys keep repeated writes of unchanged data byte-identical (dictionary ordering is
        // otherwise arbitrary); pretty printing keeps the file readable for whoever opens it.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(payload).write(to: url, options: .atomic)
    }

    /// Just the version, decoded ahead of any payload.
    private struct Envelope: Decodable {
        let version: Int
    }

    /// Copies unreadable bytes to `<name>.corrupt`, replacing any previous copy. Throwing here is
    /// the point: a caller must not start fresh over bytes it failed to preserve.
    private static func preserveCorrupt(_ data: Data, of url: URL) throws {
        try data.write(to: url.appendingPathExtension("corrupt"), options: .atomic)
    }
}

/// The `store.json` envelope: the schema version plus everything the app persists about snippets.
private struct StorePayload: Codable {
    var version: Int
    var groups: [SnippetGroup]
    var globals: [GlobalVariable]
}

/// Reads and writes `store.json` — the snippet library and its global variables.
///
/// Fail-closed: a file that cannot be decoded is copied to `store.json.corrupt` before anything
/// overwrites it, and nothing is ever written until a `load()` has succeeded, so no path through
/// this class can silently destroy a user's snippets.
public final class SnippetStore {
    private let directory: URL

    public private(set) var groups: [SnippetGroup] = []
    public private(set) var globals: [GlobalVariable] = []

    /// True when the last `load()` found bytes it could not decode and copied them to
    /// `store.json.corrupt` before seeding fresh content — the hook for telling the user their
    /// library was reset and where the old bytes went.
    public private(set) var didPreserveCorruptFile = false

    /// True only between a completed `load()` and the next `load()` attempt. Every write is gated
    /// on it: until this store has actually read the file, its empty in-memory state is not a
    /// truthful picture of what is on disk, and writing it out would be data loss.
    public private(set) var hasLoadedSuccessfully = false

    private var fileURL: URL { directory.appendingPathComponent("store.json", isDirectory: false) }

    public init(directory: URL) {
        self.directory = directory
        // Best effort: this initialiser cannot throw, so a directory that genuinely cannot be
        // created surfaces from `load()`/`save()`, which re-create it and can report the failure.
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Loads `store.json`, seeding the starter group when there is nothing usable to load.
    ///
    /// Must succeed before any write is allowed. A load that throws — a file this build cannot
    /// read, or one whose bytes could not be preserved — clears `hasLoadedSuccessfully`, so a
    /// caller that reports the error and carries on cannot then overwrite the file this refused
    /// to touch.
    public func load() throws {
        didPreserveCorruptFile = false
        hasLoadedSuccessfully = false
        switch try StoreFile.read(StorePayload.self, from: fileURL) {
        case .payload(let payload):
            // A file that decoded is left exactly as it is on disk; loading never rewrites it.
            groups = payload.groups
            globals = payload.globals
        case .missing:
            try seedStarterLibrary()
        case .corruptPreserved:
            didPreserveCorruptFile = true
            try seedStarterLibrary()
        }
        hasLoadedSuccessfully = true
    }

    /// Replaces the whole library and persists it.
    ///
    /// - Throws: `StoreError.notLoaded` if no `load()` has succeeded yet.
    public func replaceAll(groups: [SnippetGroup], globals: [GlobalVariable]) throws {
        try requireLoaded()
        // Disk first: in-memory state only advances once the bytes are written, so a failed write
        // leaves the store reporting what is actually persisted.
        try write(groups: groups, globals: globals)
        self.groups = groups
        self.globals = globals
    }

    /// Atomically writes the current library to `store.json`.
    ///
    /// - Throws: `StoreError.notLoaded` if no `load()` has succeeded yet.
    public func save() throws {
        try requireLoaded()
        try write(groups: groups, globals: globals)
    }

    /// Writes the starter library and adopts it. Used only from `load()`, which is why it bypasses
    /// the `requireLoaded()` gate that guards the public writes.
    private func seedStarterLibrary() throws {
        let seed = Self.starterSeed
        try write(groups: seed, globals: [])
        groups = seed
        globals = []
    }

    private func requireLoaded() throws {
        guard hasLoadedSuccessfully else { throw StoreError.notLoaded }
    }

    private func write(groups: [SnippetGroup], globals: [GlobalVariable]) throws {
        try StoreFile.write(StorePayload(version: StoreFile.version, groups: groups, globals: globals),
                            to: fileURL)
    }

    /// What a first run starts with: one example the user can type straight away to see that
    /// expansion works.
    private static var starterSeed: [SnippetGroup] {
        [
            SnippetGroup(name: "Examples",
                         snippets: [Snippet(triggers: [";fwrds"], content: "#@!% typing it twice.")]),
        ]
    }
}
