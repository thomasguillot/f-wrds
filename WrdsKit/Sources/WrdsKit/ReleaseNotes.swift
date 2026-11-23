import Foundation

/// GitHub release bodies → display blocks for the update window, and the DMG checksum out of the
/// same text.
///
/// Block-level markdown only (headings, bullets, paragraphs); inline markdown is
/// left in the strings for the UI to render. Updater noise is dropped here — the
/// `## Install` section, the `**Requires macOS …**` line, and the DMG checksum —
/// all of which matter on the releases page but not to someone whose already-
/// running app is about to install the update for them.
///
/// The checksum is *noise to display and evidence to verify*, which is why it is dropped by
/// `blocks(from:)` and read back out by `checksum(from:)` rather than one of the two winning. The
/// release note is where this project publishes the digest of the image it built, so it is the only
/// statement the updater has about what it is supposed to be downloading.
public enum ReleaseNotes {
    public enum Block: Equatable, Sendable {
        case heading(level: Int, text: String)
        case bullet(String)
        case paragraph(String)
    }

    public static func blocks(from body: String) -> [Block] {
        var parser = Parser()
        for raw in lines(of: body) {
            parser.consume(raw)
        }
        return parser.finish()
    }

    /// The SHA-256 the release body publishes for its own `.dmg`, lowercased, or `nil` when it
    /// publishes none.
    ///
    /// Two spellings are read, because both are things a release note plausibly says: the digest on
    /// the `**DMG SHA-256**` line itself, and the digest on the line after it — which is the shape
    /// `scripts/make-dmg.sh` prints and this project's own notes use, a label with a backticked hash
    /// beneath. A lone backticked digest with no label at all is read too, since that is the same
    /// statement with the label left off.
    ///
    /// Only a full 64-character run counts. Anything shorter is some other kind of hash — a git
    /// revision most likely — and reading one of those as a checksum would fail every download
    /// against a number that was never about the image.
    ///
    /// `nil` is not a failure: releases published before this app started verifying have no such
    /// line, and the caller's job is to install them anyway rather than refuse an update over a
    /// missing sentence.
    public static func checksum(from body: String) -> String? {
        var expectingDigest = false
        for raw in lines(of: body) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let labelled = line.lowercased().hasPrefix("**dmg sha-256**")
            if let digest = digest(in: line), labelled || expectingDigest || isChecksum(line) {
                return digest
            }
            // Only the label carries its promise to the next line. Anything else in between means
            // the label was about something that is no longer being talked about.
            expectingDigest = labelled
        }
        return nil
    }

    private static func lines(of body: String) -> [String] {
        body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    /// The one 64-character hex run in `line`, or `nil` when there is not exactly one thing that
    /// could be a SHA-256.
    ///
    /// Bounded on both sides: a run of 65 hex characters is not a digest with a spare character, it
    /// is something else entirely, and matching the first 64 of it would be inventing a digest
    /// nobody wrote.
    private static func digest(in line: String) -> String? {
        var runs: [String] = []
        var current = ""
        for character in line + " " {
            if character.isHexDigit {
                current.append(character)
            } else {
                if current.count == 64 { runs.append(current.lowercased()) }
                current = ""
            }
        }
        return runs.count == 1 ? runs[0] : nil
    }

    private struct Parser {
        private var blocks: [Block] = []
        private var paragraph: [String] = []
        private var skippingInstall = false
        private var bulletOpen = false   // true only directly after a bullet, for wrapped continuations

        mutating func consume(_ raw: String) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let (level, text) = heading(line) { consumeHeading(level: level, text: text); return }
            if skippingInstall { return }
            if line.isEmpty { flushParagraph(); bulletOpen = false; return }
            if isNoise(line) { return }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushParagraph()
                blocks.append(.bullet(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
                bulletOpen = true
                return
            }
            if bulletOpen, raw.first?.isWhitespace == true, case .bullet(let text) = blocks.last {
                blocks[blocks.count - 1] = .bullet(text + " " + line)
                return
            }
            bulletOpen = false
            paragraph.append(line)
        }

        mutating func finish() -> [Block] {
            flushParagraph()
            return blocks
        }

        private mutating func consumeHeading(level: Int, text: String) {
            flushParagraph()
            bulletOpen = false
            if level <= 2, text.lowercased().hasPrefix("install") { skippingInstall = true; return }
            // Only a level ≤2 heading ends the skipped section; nested ones stay inside it.
            if skippingInstall {
                guard level <= 2 else { return }
                skippingInstall = false
            }
            if !text.isEmpty { blocks.append(.heading(level: level, text: text)) }
        }

        private mutating func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph = []
        }
    }

    /// ATX heading: a run of `#` followed by a space or end of line.
    private static func heading(_ line: String) -> (level: Int, text: String)? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix { $0 == "#" }.count
        let rest = line.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        return (hashes, String(rest).trimmingCharacters(in: .whitespaces))
    }

    private static func isNoise(_ line: String) -> Bool {
        if line.hasPrefix("**Requires macOS") { return true }
        if line.lowercased().hasPrefix("**dmg sha-256**") { return true }
        return isChecksum(line)
    }

    /// A lone backticked hex digest — the checksum line under `**DMG SHA-256**`.
    private static func isChecksum(_ line: String) -> Bool {
        guard line.hasPrefix("`"), line.hasSuffix("`"), line.count >= 34 else { return false }
        let inner = line.dropFirst().dropLast()
        return inner.count >= 32 && inner.allSatisfy(\.isHexDigit)
    }
}
