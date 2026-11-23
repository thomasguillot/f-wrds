import Foundation

/// The whole of a user's configuration in one file: every group, every global variable, and every
/// setting. This is F Wrds' backup format.
///
/// It differs from the Espanso border in the one way that matters here: **a bundle is full
/// fidelity**. `EspansoExporter` writes what Espanso can read and names what it has to leave behind
/// — a group's app filters, either kind of `isEnabled`, a shell variable's timeout — because those
/// have nowhere to go in Espanso's schema. A bundle has room for all of it, so nothing is dropped,
/// approximated, or renumbered, and a restore puts the user back exactly where they were. An
/// Espanso export is a migration; this is the backup.
///
/// The file is JSON in the same dialect as `store.json` and `settings.json` — the same `Codable`
/// models, pretty-printed with sorted keys — so a backup is legible to anyone who opens it, and two
/// backups of an unchanged configuration are byte-identical.
public struct ConfigBundle: Codable, Equatable, Sendable {

    /// The bundle schema version this build writes, and the only one it reads.
    ///
    /// Deliberately its own number rather than `StoreFile.version`: `store.json` and a backup file
    /// are read by different code, in different situations — one is this build's own file on a path
    /// it controls, the other is a file the user kept and may hand to a different build entirely —
    /// so they must be free to change on different days. Both happen to be 1 today.
    public static let currentVersion = 1

    public var version: Int
    public var groups: [SnippetGroup]
    public var globals: [GlobalVariable]
    public var settings: AppSettings

    /// Why a file the user picked could not be restored.
    ///
    /// Two cases, because there are exactly two things worth telling the user and they need
    /// different answers: a file that is not an F Wrds backup at all (pick another file) and one
    /// written by a newer F Wrds (update, then try again). Deliberately *not* `StoreError`, whose
    /// vocabulary belongs to the app's own files: a store file that cannot be read is preserved as
    /// `.corrupt` and replaced rather than reported as malformed, and `.notLoaded` has no meaning
    /// for a file that was never this app's to begin with.
    public enum ImportError: Error, Equatable, Sendable {
        /// Not an F Wrds backup: not JSON, not shaped like a bundle, or missing a whole section.
        case malformed
        /// A bundle at a schema version this build does not read, carrying that version.
        case unsupportedVersion(Int)
    }

    // MARK: Encode

    /// The whole configuration as backup bytes.
    ///
    /// Pretty-printed with sorted keys, for the same two reasons `StoreFile.write` uses them: this
    /// is a file people open, and sorted keys are what make an unchanged configuration encode to the
    /// same bytes every time (dictionary ordering is otherwise arbitrary). Nothing records *when*
    /// the backup was taken — a timestamp inside the file would make every export differ from the
    /// last one, and the file's own modification date already says it.
    ///
    /// - Throws: `EncodingError.invalidValue` — the brief asked for this to be non-throwing, and it
    ///   cannot honestly be. `Variable.Kind.shell(command:timeoutSeconds:)` carries a `Double`, JSON
    ///   has no spelling for a non-finite one, and `JSONEncoder` refuses rather than inventing one:
    ///   an infinite or NaN timeout throws here. Nothing validates that timeout on the way in, so
    ///   the value is reachable, and the alternatives are worse — a `try!` would crash the app on
    ///   export, and quietly rewriting the user's number would make the backup a lie. Throwing lets
    ///   the caller say which snippet is unbackupable: the error names the coding path.
    public static func encode(groups: [SnippetGroup], globals: [GlobalVariable],
                              settings: AppSettings) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(ConfigBundle(version: currentVersion, groups: groups,
                                               globals: globals, settings: settings))
    }

    // MARK: Decode

    /// Reads backup bytes, refusing anything this build cannot restore faithfully.
    ///
    /// The version is decoded on its own, ahead of the payload, for the same reason `StoreFile.read`
    /// does it: a bundle from a newer F Wrds is likely to fail payload decoding too, and the user
    /// must be told their backup is newer rather than that it is broken. It is also where a future
    /// build branches to migrate instead of refusing.
    ///
    /// Version equality, not "not newer": until a version 2 exists there are no older bundles, so
    /// anything that is not `currentVersion` is a file this build cannot honestly interpret. When
    /// version 2 arrives, this guard becomes the migration switch and 1 stops being an error.
    ///
    /// A missing section is malformed rather than empty. Defaulting an absent `groups` to `[]` would
    /// restore a configuration the file never described — deleting every snippet the user has —
    /// which is precisely the failure a backup exists to prevent. The settings *object* is required
    /// for the same reason, though the keys inside it stay as lenient as `settings.json` is: a
    /// backup from a build with one toggle fewer restores that toggle at its default.
    ///
    /// - Throws: `ImportError`. The underlying `DecodingError` is deliberately flattened: the user
    ///   picked a file from a panel, and the only actionable thing to tell them is that it is not an
    ///   F Wrds backup. A coding path through a stranger's file is noise.
    public static func decode(_ data: Data) throws -> ConfigBundle {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw ImportError.malformed
        }
        guard envelope.version == currentVersion else {
            throw ImportError.unsupportedVersion(envelope.version)
        }
        guard let bundle = try? JSONDecoder().decode(ConfigBundle.self, from: data) else {
            throw ImportError.malformed
        }
        return bundle
    }

    /// Just the version, decoded ahead of any payload.
    private struct Envelope: Decodable {
        let version: Int
    }
}
