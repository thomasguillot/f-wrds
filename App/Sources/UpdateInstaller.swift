import AppKit
import Foundation
import WrdsKit

/// Installs a downloaded update in place: mount the `.dmg`, copy the app into
/// /Applications, strip quarantine, and relaunch. Mirrors the flow Newspack
/// Shots uses — the already-trusted running app performs the swap itself, so
/// Gatekeeper doesn't re-challenge the relaunch once quarantine is cleared.
@MainActor
struct UpdateInstaller {
    enum InstallError: LocalizedError {
        case missingApp
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingApp:
                return String(localized: "The update didn't contain F Wrds.")
            case let .commandFailed(detail):
                // A sentence first, then whatever the command said. On its own, `hdiutil failed:
                // …` is a line of terminal output shown in a dialogue with no explanation of what
                // it is or what it means for the app — but it is also the only specific thing
                // anyone has to go on, so it is kept rather than swallowed.
                return String(localized: "The update couldn't be installed. \(detail)")
            }
        }
    }

    // Hardcoded /Applications (not the running bundle path) so an app launched
    // from a translocated or read-only location still installs correctly.
    private let appName = "F Wrds.app"
    private let installedPath = "/Applications/F Wrds.app"

    /// Mounts the image, copies the app into /Applications, strips quarantine,
    /// and returns the installed path. Does not relaunch — the caller confirms,
    /// then calls `relaunch(path:)`.
    @discardableResult
    func install(dmgAt dmg: URL) throws -> String {
        let mountPoint = FileManager.default.temporaryDirectory
            .appendingPathComponent("fwrds-update-\(UUID().uuidString)")
        try shell("/usr/bin/hdiutil",
                  ["attach", dmg.path, "-nobrowse", "-readonly", "-mountpoint", mountPoint.path])
        var detached = false
        defer {
            if !detached { _ = try? shell("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"]) }
        }

        let newApp = mountPoint.appendingPathComponent(appName)
        guard FileManager.default.fileExists(atPath: newApp.path) else { throw InstallError.missingApp }

        try swapIn(newApp)

        _ = try? shell("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"])
        detached = true
        try? FileManager.default.removeItem(at: dmg)

        return installedPath
    }

    /// Puts `newApp` at `installedPath`, with no moment in between where nothing is installed.
    ///
    /// The obvious version of this — delete the old app, copy the new one over the top — has two
    /// failure modes and both of them cost the user their copy of F Wrds. A `ditto` that fails
    /// halfway (a full disk, a read error on the image, the machine going to sleep) leaves no app at
    /// all, on a path the user has to know to reinstall to; and a delete that quietly did not happen
    /// leaves `ditto` merging a new bundle into an old one, which is worse, because the result
    /// launches and is a mixture of two versions.
    ///
    /// So: copy first, to a sibling in the same directory — same volume, which is what makes the
    /// last step a rename rather than a second copy — and only then swap. `replaceItemAt` is the
    /// swap: the old app moves aside, the new one takes its place, the old one is deleted, and a
    /// failure anywhere in that leaves the original where it was. Either the update landed or the
    /// app the user already had is still there. There is no third outcome.
    ///
    /// The staged copy is named with a leading dot so that a crash between the copy and the swap
    /// leaves something Finder does not show and the next install overwrites, rather than a second
    /// visible F Wrds in the Applications folder.
    private func swapIn(_ newApp: URL) throws {
        let installed = URL(fileURLWithPath: installedPath)
        let staged = installed.deletingLastPathComponent()
            .appendingPathComponent(".fwrds-update-\(UUID().uuidString).app")
        try? FileManager.default.removeItem(at: staged)
        try shell("/usr/bin/ditto", [newApp.path, staged.path])
        // Downloaded apps carry com.apple.quarantine; strip it or Gatekeeper re-blocks the relaunch.
        // Done on the staged copy, so what lands at the installed path is already clear of it.
        _ = try? shell("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        do {
            if FileManager.default.fileExists(atPath: installedPath) {
                _ = try FileManager.default.replaceItemAt(installed, withItemAt: staged)
            } else {
                // Nothing to replace — the app is running from somewhere else, or /Applications was
                // cleared out. A plain move is the whole of the swap in that case.
                try FileManager.default.moveItem(at: staged, to: installed)
            }
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
    }

    /// Relaunches the freshly installed copy and terminates this process.
    ///
    /// Nothing here checks Accessibility/Input Monitoring: an unsigned app re-copied to
    /// /Applications by `install(dmgAt:)` above is, to TCC, a new binary, so macOS can drop either
    /// grant for it. That's Task 17's problem, not this one — `AppModel.onboardingShouldStartAtGrantsStep`
    /// already reruns the grants step automatically the next time the app launches, which is exactly
    /// what the relaunch below triggers. This function only has to get the new copy running again.
    func relaunch(path: String) {
        let script = Process()
        script.executableURL = URL(fileURLWithPath: "/bin/sh")
        script.arguments = ["-c", UpdateRelaunch.shellScript(
            pid: ProcessInfo.processInfo.processIdentifier, appPath: path)]
        try? script.run()
        NSApplication.shared.terminate(nil)
    }

    @discardableResult
    private func shell(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw InstallError.commandFailed("\((path as NSString).lastPathComponent) failed: \(output)")
        }
        return output
    }
}
