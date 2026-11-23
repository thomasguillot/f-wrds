import CryptoKit
import Foundation

/// What an update has to prove before it is allowed to replace the running app.
///
/// F Wrds is unsigned by design, which removes the check that would normally sit here: Gatekeeper
/// will not re-verify a bundle the already-trusted running app copies into place, and there is no
/// developer certificate for anything to be verified *against*. What is left is the two questions
/// this type answers, and they are the whole of the app's defence against installing something that
/// is not the release it went looking for.
///
/// - **Did it come from where the release said?** Every URL an update travels through — the asset
///   the release names, and every redirect hop on the way to it — has to be on GitHub. `https`
///   alone is not that question: it says the connection was private, not that the other end is who
///   was meant to answer.
/// - **Is it the bytes the release said?** A release note carrying a `**DMG SHA-256**` line is
///   naming its own artefact, and comparing the download against it catches a substituted, truncated
///   or partially-written image that every other check would let through.
///
/// Neither is a substitute for signing, and this file is not pretending otherwise. They are what an
/// unsigned distribution can honestly check for itself.
public enum UpdateIntegrity {

    /// The hosts an update may be fetched from, as domain suffixes: a host matches when it *is* one
    /// of these or sits under it.
    ///
    /// `github.com` covers the API endpoint releases are read from (`api.github.com`) and the asset
    /// URLs it hands back; `githubusercontent.com` covers where those redirect to
    /// (`objects.githubusercontent.com`), which is a different domain entirely rather than a path on
    /// the first. Both are needed, and nothing else is: this app has exactly one release channel.
    ///
    /// Matching on the suffix boundary and not on `hasSuffix` alone is the point of the `.` below —
    /// `evilgithub.com` ends with `github.com` as text and is not a GitHub host.
    private static let allowedHostSuffixes = ["github.com", "githubusercontent.com"]

    /// How much of a file to hash at a time. A disk image is tens of megabytes and there is no
    /// reason for all of it to be resident at once.
    private static let hashChunkBytes = 1024 * 1024

    /// Whether `url` is somewhere this app is willing to fetch an update from.
    ///
    /// Fail-closed on everything it cannot read as a host: no URL, no host component, an empty one.
    /// A `nil` answer here is never "probably fine".
    public static func isAllowedHost(_ url: URL?) -> Bool {
        guard let host = url?.host()?.lowercased(), !host.isEmpty else { return false }
        return allowedHostSuffixes.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    /// The SHA-256 of the file at `url`, as lowercase hex.
    ///
    /// Streamed rather than read whole: the caller is hashing a disk image it has just written to a
    /// temporary file, and loading it back into memory to hash it would double the cost of the one
    /// operation that already has the bytes on disk.
    ///
    /// - Throws: whatever `FileHandle` throws if the file cannot be opened or read.
    public static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: hashChunkBytes), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Whether the file at `url` hashes to `expected`.
    ///
    /// `expected` is compared case- and whitespace-insensitively, because it comes out of a release
    /// note somebody typed. Anything that is not a 64-character hex digest is not an answer to this
    /// question and is reported as a mismatch rather than waved through — a caller with no checksum
    /// at all should not be calling this in the first place.
    public static func fileAt(_ url: URL, matchesSHA256 expected: String) throws -> Bool {
        guard let expected = canonicalDigest(expected) else { return false }
        return try sha256Hex(ofFileAt: url) == expected
    }

    /// `text` as a lowercase 64-character hex digest, or `nil` when it is not one.
    public static func canonicalDigest(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.count == 64, trimmed.allSatisfy(\.isHexDigit) else { return nil }
        return trimmed
    }
}
