import Foundation

/// Why a shell command produced no value.
///
/// `ExpansionRenderer` catches all of these and renders a `⚠︎` where the token stood — it does not
/// look inside. The cases are for the places that have room to say more: the snippet editor's live
/// preview, a log line, an alert that can name the reason a command failed.
public enum ShellRunnerError: Error, Equatable, Sendable {
    /// The command ran to completion and reported failure.
    ///
    /// `stderr` is what it wrote to standard error, trimmed of trailing whitespace — unlike standard
    /// output, this is a message rather than a value, and a newline on the end of a label is noise.
    /// A command killed by a signal arrives here too, carrying the signal's number as its `code`
    /// (which a shell would report as 128 + n).
    case nonZeroExit(code: Int32, stderr: String)
    /// The command outlived the timeout it was given, and was killed. The caller passed the timeout
    /// in, so the error does not repeat it back.
    case timedOut
    /// The command wrote more than `limitBytes` to standard output. Nothing is returned: half a
    /// value pasted into the user's document would be worse than none.
    case outputTooLarge(limitBytes: Int)
}

/// Runs a shell command for a shell variable, with a deadline.
///
/// This is the production implementation of `RenderContext.runShell`, which the app layer injects at
/// startup; the default in `RenderContext` throws, so a renderer nobody wired a shell into cannot
/// silently render nothing where a command's output belonged.
///
/// **Output is returned raw** — every byte the command wrote to standard output, trailing newline
/// and all. Trimming belongs to `ExpansionRenderer`, which takes trailing newlines and carriage
/// returns off and deliberately leaves leading whitespace alone. Keeping that decision in one place
/// means it can be changed in one place, and means this type stays a faithful `Process` wrapper:
/// `echo hello` is `"hello\n"` here and `"hello"` by the time it reaches the document.
///
/// **Standard error is captured, not merged.** It is the payload of `ShellRunnerError.nonZeroExit`,
/// never part of a returned value: a command that warns on stderr and still succeeds must not paste
/// its warning into the user's sentence.
///
/// **`/bin/zsh -lc`, a login shell.** The cost is startup — sourcing `/etc/zprofile`, `~/.zprofile`
/// and `~/.zshrc` runs `path_helper` and whatever the user put there, tens of milliseconds on a
/// normal machine and more on a heavily customised one, paid on *every* expansion because each run
/// is a fresh process. It buys the environment the user expects: a snippet calling `gh`, `pyenv` or
/// anything else installed by a version manager finds it, because `PATH` is the one they see in
/// their terminal rather than the sparse one a GUI app inherits from `launchd`. For a variable that
/// only ever runs on an expansion the user asked for, that is the right side of the trade.
///
/// Safe to call from any thread, and from several at once: everything it touches is created inside
/// `run` and never escapes it.
public enum ShellRunner {

    /// The most standard output a command may produce before it is refused.
    ///
    /// A snippet is a paste into a document, so anything near this is already a mistake — the limit
    /// is here so that `cat /dev/urandom` in a snippet costs an error rather than the app's memory.
    /// Internal rather than public: `ShellRunnerError.outputTooLarge` carries the number to whoever
    /// has to phrase it, which is the only place outside this file that has ever needed it.
    static let outputLimitBytes = 10 * 1024 * 1024

    /// The longest budget treated as a real deadline. Past this, `run` waits without one.
    ///
    /// `DispatchTime` counts nanoseconds in an `Int64`, so it runs out around 292 years, and a
    /// `timeoutSeconds` decoded from a snippet file is not checked by anything before it arrives
    /// here. Dispatch's own `Double` conversion saturates to "forever" today rather than trapping —
    /// measured, not assumed — so this branch changes no behaviour on this toolchain; it is here so
    /// the intent is in the source rather than resting on that, since the same overlay converted
    /// unguarded (and so trapped) in living memory. A century is past any deadline a person means
    /// and a long way inside what the arithmetic holds.
    private static let longestBudget = 100.0 * 365 * 24 * 60 * 60

    /// The most standard error kept for an error message. An explanation longer than this is not a
    /// better explanation, and it is never the value.
    private static let errorLimitBytes = 64 * 1024

    /// `/bin/zsh` rather than `$SHELL`: the app's own environment comes from `launchd`, where
    /// `$SHELL` may be absent or stale, and zsh is what macOS ships and what the login files below
    /// are written for.
    private static let shell = URL(fileURLWithPath: "/bin/zsh")

    /// How long a command has to exit after being asked politely, before it is killed outright, and
    /// how long output already in flight has to arrive. Short enough not to blunt the timeout the
    /// caller asked for, long enough for a shell to run an `EXIT` trap.
    private static let grace = 0.2

    /// Runs `command` and returns everything it wrote to standard output.
    ///
    /// - Parameters:
    ///   - command: shell source, not an argument vector — pipes, `&&`, globs and functions from the
    ///     user's profile all work, and nothing here quotes anything for them.
    ///   - timeout: seconds the command may run for, measured from launch. Zero, negative or `NaN`
    ///     means no time at all — the command is killed and `.timedOut` thrown — and `.infinity`
    ///     means no deadline, for a caller that does its own waiting.
    /// - Returns: standard output, decoded as UTF-8 with invalid bytes replaced rather than
    ///   rejected — a command that emits a stray byte should still expand.
    /// - Throws: `ShellRunnerError` when the command fails, times out or floods; whatever
    ///   `Process.run()` throws if the shell itself cannot be launched.
    public static func run(_ command: String, timeout: Double) throws -> String {
        let process = Process()
        process.executableURL = shell
        process.arguments = ["-lc", command]

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        // A command that reads standard input gets end-of-file rather than the app's own descriptor,
        // which has no terminal behind it: `cat` with no argument ends instead of hanging until the
        // timeout, and nothing the user is typing can be swallowed by a snippet.
        process.standardInput = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        try process.run()

        let outputDrain = StreamDrain(output, limitBytes: outputLimitBytes)
        let errorDrain = StreamDrain(errors, limitBytes: errorLimitBytes)
        let drained = DispatchGroup()
        outputDrain.start(in: drained)
        errorDrain.start(in: drained)

        // Read before the process can be reaped: a pid with no process behind it has no group.
        let group = groupToSweep(of: process)

        // A NaN budget is a broken config value, not a licence to wait forever; anything past a
        // human lifetime is a caller saying it will do its own waiting.
        let budget = timeout.isNaN ? 0 : max(timeout, 0)
        let deadline = budget > longestBudget ? DispatchTime.distantFuture : .now() + budget
        if exited.wait(timeout: deadline) == .timedOut {
            stop(process, group: group, exited: exited)
            _ = drained.wait(timeout: .now() + grace)
            throw ShellRunnerError.timedOut
        }

        // The command is gone, so anything it wrote is already in the pipe and end-of-file is a
        // moment away — unless it left something behind that inherited the pipe, in which case
        // end-of-file never comes and the wait is what stops this from being a hang. Whatever
        // arrived is returned; a background daemon holding the pipe open is not the user's problem.
        _ = drained.wait(timeout: .now() + grace)

        let status = process.terminationStatus
        guard status == 0 else {
            throw ShellRunnerError.nonZeroExit(code: status, stderr: message(from: errorDrain))
        }
        guard !outputDrain.overflowed else {
            throw ShellRunnerError.outputTooLarge(limitBytes: outputLimitBytes)
        }
        return text(outputDrain.collected)
    }

    /// Decodes a stream as text.
    ///
    /// Invalid bytes are replaced rather than rejected — a command that emits one stray byte should
    /// still expand, where the failable initialiser the linter prefers would turn the whole value
    /// into `nil` and, at every call site here, into nothing at all.
    private static func text(_ data: Data) -> String {
        // swiftlint:disable:next optional_data_string_conversion
        String(decoding: data, as: UTF8.self)
    }

    /// The process group to sweep when a command runs out of time, or `0` when there is not a safe
    /// one to sweep.
    ///
    /// Foundation launches a `Process` as the leader of a *new* process group, which is what makes
    /// the sweep both possible and safe: the group holds the shell and every process it started, and
    /// nothing of this app's. It is checked rather than assumed, because the cost of being wrong is
    /// `kill(-group)` taking down the app that called it.
    private static func groupToSweep(of process: Process) -> pid_t {
        let pid = process.processIdentifier
        let group = getpgid(pid)
        guard group > 0, group == pid, group != getpgrp() else { return 0 }
        return group
    }

    /// Ends a command that has run out of time, and does not return until it is gone — so no
    /// half-killed process outlives the call, and Foundation has reaped the child rather than
    /// leaving a zombie.
    private static func stop(_ process: Process, group: pid_t, exited: DispatchSemaphore) {
        // Politely first. A command with an `EXIT` trap gets to run it, which is the difference
        // between a half-written file and none.
        if process.isRunning { process.terminate() }
        let reaped = exited.wait(timeout: .now() + grace) == .success

        // Then the sweep, whether or not the shell itself is still there. `terminate()` signals the
        // shell alone, so a compound command's children — `sleep` in `touch x; sleep 5` runs as a
        // grandchild, where in a bare `sleep 5` zsh execs it in place — would otherwise be orphaned
        // and keep running with nobody waiting on them.
        if group > 0 {
            kill(-group, SIGKILL)
        } else if !reaped {
            kill(process.processIdentifier, SIGKILL)
        }
        // Not returning until Foundation has seen the child exit is what keeps a killed command from
        // outliving the call — and what makes it Foundation's business to reap, rather than a zombie.
        if !reaped { _ = exited.wait(timeout: .now() + grace) }
    }

    /// What a failed command said, as something a person could be shown.
    ///
    /// A message past the cap ends in an ellipsis, so what is shown is never a fragment passing
    /// itself off as the whole of what the command said.
    private static func message(from drain: StreamDrain) -> String {
        var message = text(drain.collected)
        while let last = message.last, last.isWhitespace { message.removeLast() }
        if drain.overflowed { message += "…" }
        return message
    }
}

/// Reads one of a command's output streams to its end, on a thread of its own.
///
/// Reading has to happen *while* the command runs rather than after it exits: a pipe holds 64 KiB,
/// and a command that fills one blocks forever waiting for a reader that is waiting for it to exit.
/// Chunk by chunk rather than `readDataToEndOfFile()` for the same reason in reverse — a stream that
/// never closes still yields what did arrive.
///
/// A dedicated `Thread` rather than `DispatchQueue.global()`, and that is not a style choice. These
/// reads block, and a stream can fail to end: a daemon the command left behind inherits the pipe and
/// holds the write end open for as long as it lives, parking this reader for the same span. On the
/// shared pool that is a leak with the whole app inside its blast radius — libdispatch caps its
/// worker threads per quality-of-service band, so enough parked readers starve every other
/// `global()` user in the process, and this file degrades worst of all: with no worker free, the
/// drain for the *next* command never starts, its pipe fills at 64 KiB, the command blocks on write,
/// and every shell variable times out. A parked `Thread` costs its stack and nothing anyone else
/// needs.
private final class StreamDrain: @unchecked Sendable {

    private let handle: FileHandle
    private let limitBytes: Int
    /// Guards the two fields below, which the reading thread writes and the calling thread reads.
    private let lock = NSLock()
    private var buffer = Data()
    private var overflow = false

    init(_ pipe: Pipe, limitBytes: Int) {
        self.handle = pipe.fileHandleForReading
        self.limitBytes = limitBytes
    }

    /// Starts reading, and leaves `group` at end of stream.
    func start(in group: DispatchGroup) {
        group.enter()
        let thread = Thread { [self] in
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                lock.lock()
                if overflow || buffer.count + chunk.count > limitBytes {
                    // Past the limit the stream is still drained, just dropped: leaving the pipe
                    // unread would block the command instead of letting it finish or be killed on
                    // schedule, and the caller learns about it from `overflowed`.
                    //
                    // Sticky, because a limit that only skipped the chunks that *didn't* fit would
                    // splice the start of the stream onto whatever later happened to be small
                    // enough and hand back the join as if it were the whole truth.
                    overflow = true
                } else {
                    buffer.append(chunk)
                }
                lock.unlock()
            }
            group.leave()
        }
        thread.name = "WrdsKit.ShellRunner drain"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Everything read so far.
    var collected: Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    /// Whether the stream carried more than its limit, and so what `collected` holds is a fragment.
    var overflowed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return overflow
    }
}
