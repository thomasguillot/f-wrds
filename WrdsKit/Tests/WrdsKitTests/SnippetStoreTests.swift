import Foundation
import Testing
import WrdsKit

/// Runs `body` against a freshly created, empty directory that is removed afterwards.
private func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("SnippetStoreTests-\(UUID().uuidString)", isDirectory: true)
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

@Suite("SnippetStore")
struct SnippetStoreTests {

    private static let seedContent = "#@!% typing it twice."

    private static func storeURL(_ directory: URL) -> URL {
        directory.appendingPathComponent("store.json", isDirectory: false)
    }

    private static func corruptURL(_ directory: URL) -> URL {
        directory.appendingPathComponent("store.json.corrupt", isDirectory: false)
    }

    // MARK: Round-trip

    @Test("Groups and globals survive a save and a load by a separate store")
    func roundTripsThroughDisk() throws {
        try withTemporaryDirectory { directory in
            let groups = [
                SnippetGroup(
                    name: "Work",
                    snippets: [
                        Snippet(triggers: [":wp"], label: "WordPress", content: "WordPress {{when}}",
                                wordBoundary: true, propagateCase: true, uppercaseStyle: .uppercase,
                                variables: [Variable(name: "when",
                                                     kind: .date(format: "%Y", offsetSeconds: -3600))],
                                unmapped: ["image_path": "~/shot.png"]),
                    ],
                    onlyInApps: ["com.apple.Safari"],
                    neverInApps: ["com.apple.Terminal"],
                    isEnabled: false),
                SnippetGroup(name: "Empty"),
            ]
            let globals = [GlobalVariable(variable: Variable(name: "sig", kind: .echo(value: "Thomas")))]

            let store = SnippetStore(directory: directory)
            try store.load()
            try store.replaceAll(groups: groups, globals: globals)

            let reloaded = SnippetStore(directory: directory)
            try reloaded.load()

            #expect(reloaded.groups == groups)
            #expect(reloaded.globals == globals)
            #expect(reloaded.didPreserveCorruptFile == false)
        }
    }

    @Test("replaceAll persists immediately, without a separate save")
    func replaceAllPersistsImmediately() throws {
        try withTemporaryDirectory { directory in
            let store = SnippetStore(directory: directory)
            try store.load()

            try store.replaceAll(groups: [SnippetGroup(name: "Only")], globals: [])

            let object = try jsonObject(at: Self.storeURL(directory))
            #expect(object["version"] as? Int == 1)
            #expect(store.groups.map(\.name) == ["Only"])
        }
    }

    @Test("save() rewrites the file from the store's current state")
    func saveRewritesTheFile() throws {
        try withTemporaryDirectory { directory in
            let store = SnippetStore(directory: directory)
            try store.load()
            try FileManager.default.removeItem(at: Self.storeURL(directory))

            try store.save()

            let reloaded = SnippetStore(directory: directory)
            try reloaded.load()
            #expect(reloaded.groups == store.groups)
        }
    }

    // MARK: On-disk shape

    @Test("A written store carries the version alongside its groups and globals")
    func writesVersionedEnvelope() throws {
        try withTemporaryDirectory { directory in
            let store = SnippetStore(directory: directory)
            try store.load()
            try store.replaceAll(
                groups: [SnippetGroup(name: "Work")],
                globals: [GlobalVariable(variable: Variable(name: "sig", kind: .clipboard))])

            let object = try jsonObject(at: Self.storeURL(directory))

            #expect(object["version"] as? Int == 1)
            #expect((object["groups"] as? [Any])?.count == 1)
            #expect((object["globals"] as? [Any])?.count == 1)
        }
    }

    // MARK: Seeding

    @Test("Loading with no file on disk seeds the Examples group and writes it out")
    func seedsStarterGroupWhenFileIsMissing() throws {
        try withTemporaryDirectory { directory in
            let store = SnippetStore(directory: directory)

            try store.load()

            #expect(store.groups.count == 1)
            #expect(store.groups.first?.name == "Examples")
            #expect(store.groups.first?.snippets.count == 1)
            #expect(store.groups.first?.snippets.first?.triggers == [";fwrds"])
            #expect(store.groups.first?.snippets.first?.content == Self.seedContent)
            #expect(store.globals.isEmpty)
            #expect(store.didPreserveCorruptFile == false)
            // The seed reaches disk on first load, so a first run leaves an inspectable file.
            let object = try jsonObject(at: Self.storeURL(directory))
            #expect(object["version"] as? Int == 1)
        }
    }

    @Test("A valid but empty store is loaded as-is: neither re-seeded nor rewritten")
    func validStoreIsNeitherReseededNorRewritten() throws {
        try withTemporaryDirectory { directory in
            let fileURL = Self.storeURL(directory)
            let original = Data(#"{ "version" : 1, "groups" : [], "globals" : [] }"#.utf8)
            try original.write(to: fileURL)

            let store = SnippetStore(directory: directory)
            try store.load()

            #expect(store.groups.isEmpty)
            #expect(store.globals.isEmpty)
            let onDisk = try Data(contentsOf: fileURL)
            #expect(onDisk == original, "loading a good file must not rewrite it")
        }
    }

    // MARK: Corruption

    @Test("Undecodable bytes are copied to store.json.corrupt before a fresh seed replaces them")
    func preservesCorruptBytesAndSeedsFresh() throws {
        try withTemporaryDirectory { directory in
            let garbage = Data("{ this is not json ⚠️".utf8)
            try garbage.write(to: Self.storeURL(directory))

            let store = SnippetStore(directory: directory)
            try store.load()

            let preserved = try Data(contentsOf: Self.corruptURL(directory))
            #expect(preserved == garbage, "the original bytes must survive byte-for-byte")
            #expect(store.didPreserveCorruptFile)
            #expect(store.groups.first?.name == "Examples")
            // The fresh seed replaced the garbage, so the store is usable again.
            let object = try jsonObject(at: Self.storeURL(directory))
            #expect(object["version"] as? Int == 1)
        }
    }

    @Test("A second corruption replaces the previous .corrupt copy")
    func corruptCopyIsOverwritten() throws {
        try withTemporaryDirectory { directory in
            try Data("older corruption".utf8).write(to: Self.corruptURL(directory))
            let garbage = Data("newer corruption }{".utf8)
            try garbage.write(to: Self.storeURL(directory))

            let store = SnippetStore(directory: directory)
            try store.load()

            let preserved = try Data(contentsOf: Self.corruptURL(directory))
            #expect(preserved == garbage)
        }
    }

    @Test("A version-1 file whose payload no longer decodes is preserved, not silently dropped")
    func malformedPayloadAtCurrentVersionIsPreserved() throws {
        try withTemporaryDirectory { directory in
            // A group missing required keys — the shape a future model change could leave behind.
            let stale = Data("""
                {"version":1,"groups":[{"id":"00000000-0000-0000-0000-000000000001","name":"Work"}],\
                "globals":[]}
                """.utf8)
            try stale.write(to: Self.storeURL(directory))

            let store = SnippetStore(directory: directory)
            try store.load()

            let preserved = try Data(contentsOf: Self.corruptURL(directory))
            #expect(preserved == stale)
            #expect(store.didPreserveCorruptFile)
            #expect(store.groups.first?.name == "Examples")
        }
    }

    // MARK: Versioning

    @Test("A store from a newer schema version throws and is left untouched")
    func unsupportedVersionThrowsWithoutTouchingTheFile() throws {
        try withTemporaryDirectory { directory in
            let fileURL = Self.storeURL(directory)
            let future = Data(#"{"version":2,"groups":[],"globals":[]}"#.utf8)
            try future.write(to: fileURL)

            let store = SnippetStore(directory: directory)

            #expect(throws: StoreError.unsupportedVersion(2)) { try store.load() }
            let onDisk = try Data(contentsOf: fileURL)
            #expect(onDisk == future, "a file we cannot read must not be rewritten or reset")
            #expect(FileManager.default.fileExists(atPath: Self.corruptURL(directory).path) == false)
        }
    }

    // MARK: Writes require a successful load

    @Test("A store whose load failed refuses to write over the file it could not read")
    func writesAreRefusedAfterAFailedLoad() throws {
        try withTemporaryDirectory { directory in
            let fileURL = Self.storeURL(directory)
            let future = Data(#"{"version":2,"groups":[],"globals":[]}"#.utf8)
            try future.write(to: fileURL)

            let store = SnippetStore(directory: directory)
            #expect(throws: StoreError.unsupportedVersion(2)) { try store.load() }
            #expect(store.hasLoadedSuccessfully == false)

            // The app reports the error and stays open; anything the user then touches must not
            // stamp this build's empty library over the file load() deliberately left alone.
            #expect(throws: StoreError.notLoaded) { try store.save() }
            #expect(throws: StoreError.notLoaded) {
                try store.replaceAll(groups: [SnippetGroup(name: "Work")], globals: [])
            }
            let onDisk = try Data(contentsOf: fileURL)
            #expect(onDisk == future)
            #expect(FileManager.default.fileExists(atPath: Self.corruptURL(directory).path) == false)
        }
    }

    @Test("A store that never loaded refuses to write over an existing file")
    func writesAreRefusedBeforeAnyLoad() throws {
        try withTemporaryDirectory { directory in
            let existing = Data(#"{"version":1,"groups":[],"globals":[]}"#.utf8)
            try existing.write(to: Self.storeURL(directory))

            let store = SnippetStore(directory: directory)

            #expect(throws: StoreError.notLoaded) { try store.replaceAll(groups: [], globals: []) }
            #expect(throws: StoreError.notLoaded) { try store.save() }
            let onDisk = try Data(contentsOf: Self.storeURL(directory))
            #expect(onDisk == existing)
        }
    }

    @Test("A store that never loaded refuses to write even when no file exists yet")
    func writesAreRefusedBeforeAnyLoadOnAFreshDirectory() throws {
        try withTemporaryDirectory { directory in
            let store = SnippetStore(directory: directory)

            // Unconditional by design: writing from a store that never read disk would establish an
            // empty library where load() would have seeded the starter group, and "is there a file?"
            // is a race anyway. Load first, always.
            #expect(throws: StoreError.notLoaded) { try store.save() }
            #expect(FileManager.default.fileExists(atPath: Self.storeURL(directory).path) == false)
        }
    }

    @Test("A successful load unlocks writing")
    func loadUnlocksWriting() throws {
        try withTemporaryDirectory { directory in
            let store = SnippetStore(directory: directory)
            #expect(store.hasLoadedSuccessfully == false)

            try store.load()

            #expect(store.hasLoadedSuccessfully)
            try store.replaceAll(groups: [SnippetGroup(name: "Work")], globals: [])
            #expect(store.groups.map(\.name) == ["Work"])
        }
    }

    // MARK: Directory

    @Test("The store directory is created when it does not exist yet")
    func initCreatesMissingDirectory() throws {
        try withTemporaryDirectory { directory in
            let nested = directory.appendingPathComponent("FWrds", isDirectory: true)

            _ = SnippetStore(directory: nested)

            #expect(FileManager.default.fileExists(atPath: nested.path))
        }
    }
}
