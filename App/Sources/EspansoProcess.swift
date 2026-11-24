import Darwin
import Foundation

/// Finds a running Espanso, and stops it.
///
/// Two expanders watching the same keyboard both answer a trigger they share: each deletes it and
/// pastes, and the text comes out garbled. People who switch from Espanso usually import its
/// snippets, so every trigger is shared, and Espanso often still starts at login.
///
/// Espanso runs as a background daemon launched from its command-line tool rather than as a regular
/// app, so `NSWorkspace.runningApplications` does not list it. The process table does.
enum EspansoProcess {

    private static let processName = "espanso"
    private static let stopTimeout: TimeInterval = 5

    /// Whether any Espanso process is running.
    static var isRunning: Bool { !runningPIDs().isEmpty }

    /// Stops Espanso the way its own `espanso stop` does, then terminates anything still left.
    ///
    /// Blocks for up to a few seconds, so call it off the main actor.
    static func stop() {
        let pids = runningPIDs()
        guard !pids.isEmpty else { return }
        if let path = pids.lazy.compactMap(executablePath(of:)).first {
            runStop(executable: path)
        }
        for pid in runningPIDs() {
            kill(pid, SIGTERM)
        }
    }

    private static func runningPIDs() -> [pid_t] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 32)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        return pids.prefix(Int(count)).filter { $0 > 0 && name(of: $0) == processName }
    }

    private static func name(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 64)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return buffer.withUnsafeBufferPointer { String(validatingCString: $0.baseAddress!) }
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return buffer.withUnsafeBufferPointer { String(validatingCString: $0.baseAddress!) }
    }

    private static func runStop(executable: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["stop"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return
        }
        if finished.wait(timeout: .now() + stopTimeout) == .timedOut {
            process.terminate()
        }
    }
}
