import Foundation
import Testing
@testable import WrdsKit

@Suite struct UpdateIntegrityTests {

    // MARK: Where an update may come from

    @Test func acceptsGitHubAndItsAssetHosts() {
        #expect(UpdateIntegrity.isAllowedHost(URL(string: "https://api.github.com/repos/x/y/releases")))
        #expect(UpdateIntegrity.isAllowedHost(URL(string: "https://github.com/x/y/releases/download/v1/a.dmg")))
        #expect(UpdateIntegrity.isAllowedHost(URL(string: "https://objects.githubusercontent.com/blob")))
        #expect(UpdateIntegrity.isAllowedHost(URL(string: "https://GITHUB.COM/x/y")))
    }

    @Test func rejectsAnythingElse() {
        #expect(!UpdateIntegrity.isAllowedHost(URL(string: "https://example.com/a.dmg")))
        // Ends with the allowed text and is a different domain — the whole reason the match is on a
        // label boundary rather than on `hasSuffix` alone.
        #expect(!UpdateIntegrity.isAllowedHost(URL(string: "https://evilgithub.com/a.dmg")))
        #expect(!UpdateIntegrity.isAllowedHost(URL(string: "https://github.com.evil.net/a.dmg")))
    }

    @Test func rejectsWhatItCannotReadAsAHost() {
        #expect(!UpdateIntegrity.isAllowedHost(nil))
        #expect(!UpdateIntegrity.isAllowedHost(URL(string: "file:///tmp/a.dmg")))
        #expect(!UpdateIntegrity.isAllowedHost(URL(string: "a.dmg")))
    }

    // MARK: What it is

    @Test func hashesAFileToItsKnownDigest() throws {
        // `printf 'f wrds' | shasum -a 256`
        let url = try write("f wrds")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(try UpdateIntegrity.sha256Hex(ofFileAt: url)
            == "5112d458e9fc58ef7b78a0df11bce1408fce43e0e0139c8848c8b89509257c78")
    }

    @Test func hashesAFileLongerThanOneChunk() throws {
        // Streamed in megabyte chunks, so a file spanning several has to come out the same as the
        // same bytes hashed whole.
        let data = Data(repeating: 0x61, count: 3 * 1024 * 1024 + 17)
        let url = try write(data)
        defer { try? FileManager.default.removeItem(at: url) }

        let whole = try write(data)
        defer { try? FileManager.default.removeItem(at: whole) }

        #expect(try UpdateIntegrity.sha256Hex(ofFileAt: url)
            == UpdateIntegrity.sha256Hex(ofFileAt: whole))
    }

    @Test func matchesAreCaseAndWhitespaceInsensitive() throws {
        let url = try write("f wrds")
        defer { try? FileManager.default.removeItem(at: url) }
        let digest = try UpdateIntegrity.sha256Hex(ofFileAt: url)

        #expect(try UpdateIntegrity.fileAt(url, matchesSHA256: digest))
        #expect(try UpdateIntegrity.fileAt(url, matchesSHA256: "  \(digest.uppercased())\n"))
    }

    @Test func aDifferentFileDoesNotMatch() throws {
        let url = try write("f wrds")
        let other = try write("f wrdz")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: other)
        }

        let digest = try UpdateIntegrity.sha256Hex(ofFileAt: other)
        #expect(try !UpdateIntegrity.fileAt(url, matchesSHA256: digest))
    }

    @Test func anythingThatIsNotADigestIsAMismatch() throws {
        let url = try write("f wrds")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(try !UpdateIntegrity.fileAt(url, matchesSHA256: ""))
        #expect(try !UpdateIntegrity.fileAt(url, matchesSHA256: "deadbeef"))
        #expect(UpdateIntegrity.canonicalDigest("not a digest") == nil)
        #expect(UpdateIntegrity.canonicalDigest(String(repeating: "A", count: 64))
            == String(repeating: "a", count: 64))
    }

    private func write(_ text: String) throws -> URL {
        try write(Data(text.utf8))
    }

    private func write(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wrdskit-integrity-\(UUID().uuidString)")
        try data.write(to: url)
        return url
    }
}
