import Foundation
import Testing
// `@testable` for `outputLimitBytes` alone, which is internal because the error carries the number
// to anyone who has to phrase it. Everything else here is exercised through the public surface.
@testable import WrdsKit

/// Generous enough that a loaded machine running the whole suite in parallel cannot trip it, and
/// short enough that a hung command fails the run rather than stalling it.
private let generous = 15.0

@Suite("ShellRunner")
struct ShellRunnerTests {

    // MARK: What comes back

    @Test("Output comes back raw, trailing newline and all")
    func returnsOutputRaw() throws {
        // Raw on purpose: `ExpansionRenderer` owns trim semantics, and it trims trailing newlines
        // only. A runner that trimmed too would make that decision unreachable and untestable.
        #expect(try ShellRunner.run("echo hello", timeout: generous) == "hello\n")
    }

    @Test("Interior newlines survive and a missing trailing one is not invented")
    func preservesInteriorNewlines() throws {
        #expect(try ShellRunner.run("printf 'a\\nb'", timeout: generous) == "a\nb")
    }

    @Test("Leading whitespace is left alone")
    func preservesLeadingWhitespace() throws {
        #expect(try ShellRunner.run("printf '  indented'", timeout: generous) == "  indented")
    }

    @Test("A command that prints nothing returns the empty string")
    func returnsEmptyOutput() throws {
        #expect(try ShellRunner.run("true", timeout: generous) == "")
    }

    @Test("An empty command is not an error")
    func acceptsEmptyCommand() throws {
        #expect(try ShellRunner.run("", timeout: generous) == "")
    }

    @Test("Output larger than the pipe buffer arrives whole")
    func readsPastThePipeBuffer() throws {
        // 200_000 bytes, three times the 64 KiB pipe buffer: a runner that waits for exit before
        // reading deadlocks here rather than failing an expectation.
        let output = try ShellRunner.run("yes x | head -n 100000", timeout: generous)
        #expect(output.count == 200_000)
        #expect(output.hasPrefix("x\nx\n"))
    }

    @Test("Standard error stays out of the returned output")
    func keepsStandardErrorOutOfOutput() throws {
        #expect(try ShellRunner.run("echo out; echo err >&2", timeout: generous) == "out\n")
    }

    // MARK: Failure

    @Test("A non-zero exit throws with the code")
    func throwsOnNonZeroExit() {
        #expect(throws: ShellRunnerError.nonZeroExit(code: 3, stderr: "")) {
            try ShellRunner.run("exit 3", timeout: generous)
        }
    }

    @Test("The error carries what the command wrote to standard error")
    func carriesStandardErrorInTheError() {
        #expect(throws: ShellRunnerError.nonZeroExit(code: 1, stderr: "no such thing")) {
            try ShellRunner.run("echo out; echo 'no such thing' >&2; exit 1", timeout: generous)
        }
    }

    @Test("A command killed by a signal is a failure, not an empty value")
    func treatsSignalAsFailure() {
        #expect(throws: ShellRunnerError.self) {
            try ShellRunner.run("kill -9 $$", timeout: generous)
        }
    }

    @Test("A standard error message past the cap is truncated, not spliced")
    func doesNotSpliceTruncatedStandardError() {
        // Three writes, paused apart so each is read on its own, and the sizes are the test. 30 KB
        // settles the buffer well below the 64 KiB cap; 60 KB then cannot fit and is dropped, which
        // leaves headroom; and the short line that follows fits in it. A cap that only skipped the
        // chunks too big to fit would join this tail onto that head and hand back the seam as what
        // the command said. (Overflowing in one go instead would fill the buffer *to* the cap, where
        // nothing fits afterwards and the splice cannot be seen.)
        let command = """
            yes a | head -c 30000 >&2; sleep 0.2; yes b | head -c 60000 >&2; sleep 0.2; \
            echo TAILMARKER >&2; exit 1
            """
        do {
            _ = try ShellRunner.run(command, timeout: generous)
            Issue.record("expected the command to fail")
        } catch let error as ShellRunnerError {
            guard case .nonZeroExit(_, let stderr) = error else {
                Issue.record("expected a non-zero exit, got \(error)")
                return
            }
            #expect(!stderr.contains("TAILMARKER"))
            // Truncation says so, so nobody reads a fragment as the whole of it.
            #expect(stderr.hasSuffix("…"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("Output past the limit throws rather than growing without bound")
    func throwsOnRunawayOutput() {
        #expect(throws: ShellRunnerError.outputTooLarge(limitBytes: ShellRunner.outputLimitBytes)) {
            try ShellRunner.run("head -c \(ShellRunner.outputLimitBytes + 1) /dev/zero", timeout: generous)
        }
    }

    // MARK: The timeout

    @Test("A command that outlives its timeout throws, and quickly")
    func throwsOnTimeout() {
        var thrown: (any Error)?
        let elapsed = ContinuousClock().measure {
            do { _ = try ShellRunner.run("sleep 5", timeout: 0.5) } catch { thrown = error }
        }
        #expect(thrown as? ShellRunnerError == .timedOut)
        // The point of the timeout is that the caller is not left waiting for the command's own
        // clock: five seconds of sleep have to cost well under two.
        #expect(elapsed < .seconds(2))
    }

    @Test("A timeout of zero is a budget, not a licence to wait")
    func honoursAZeroTimeout() {
        let elapsed = ContinuousClock().measure {
            #expect(throws: ShellRunnerError.timedOut) {
                try ShellRunner.run("sleep 5", timeout: 0)
            }
        }
        #expect(elapsed < .seconds(2))
    }

    @Test("A timeout too large to be a deadline is not a crash")
    func survivesAnEnormousTimeout() throws {
        // `timeoutSeconds` arrives from a decoded snippet file and nothing validates it on the way
        // here, so these are the values a corrupt library hands over. Dispatch saturates the
        // conversion today, which is why this passes with or without `run`'s own ceiling — it is a
        // guard against the arithmetic, not a proof of the ceiling.
        #expect(try ShellRunner.run("echo ok", timeout: 1e10) == "ok\n")
        #expect(try ShellRunner.run("echo ok", timeout: .greatestFiniteMagnitude) == "ok\n")
        #expect(try ShellRunner.run("echo ok", timeout: .infinity) == "ok\n")
    }

    @Test("A timed-out command leaves nothing of itself running, even ignoring the polite ask")
    func killsTheWholeProcessTree() throws {
        // Three things at once, and each is load-bearing. The shell traps SIGTERM, so being asked
        // politely achieves nothing and the runner has to escalate — plenty of real CLIs trap it.
        // The trailing `true` keeps `sleep` from being the command zsh execs in place, so it is a
        // real grandchild: signalling the shell alone orphans it and leaves it running for the next
        // quarter of an hour. And the duration is unique to this run, so a leak from an earlier one
        // can neither pass nor fail the check.
        let seconds = "9\(Int.random(in: 10_000...99_999)).5"
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("wrds-shell-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        // If the runner ever stops killing it, this test fails *and* tidies up after itself rather
        // than leaving an eleven-day sleep on the developer's machine for every red run.
        defer { killProcesses(matching: "sleep \(seconds)") }

        #expect(throws: ShellRunnerError.timedOut) {
            try ShellRunner.run("trap '' TERM; touch '\(marker.path)'; sleep \(seconds); true",
                                timeout: 0.5)
        }
        // Proof the command actually ran, so the check below cannot pass by never having started.
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(waitForNoProcess(matching: "sleep \(seconds)", upTo: 5))
    }

    // MARK: The shell it runs in

    @Test("Commands run under a zsh login shell")
    func runsUnderAZshLoginShell() throws {
        // `-l` is the whole reason a user's own PATH and profile are in scope: a snippet calling
        // `gh` or a pyenv shim has to find it.
        #expect(try ShellRunner.run("[[ -o login ]] && echo yes", timeout: generous) == "yes\n")
        #expect(try ShellRunner.run("echo $ZSH_VERSION", timeout: generous) != "\n")
    }

    @Test("The command is a shell command, not an argument vector")
    func runsShellSyntax() throws {
        #expect(try ShellRunner.run("echo a && echo b | tr b c", timeout: generous) == "a\nc\n")
    }

    // MARK: The fit with the renderer

    @Test("Wired into a RenderContext, raw output is what the renderer trims")
    func fitsTheRenderContext() {
        // The point of the whole type, and the one line Task 12 has to write: if `ShellRunner.run`
        // ever stopped satisfying `RenderContext.runShell` — a `@Sendable` closure — this would stop
        // compiling here rather than in the app.
        let context = RenderContext(runShell: ShellRunner.run)
        let snippet = Snippet(
            triggers: [":greet"], content: "{{out}}!",
            variables: [Variable(name: "out",
                                 kind: .shell(command: "echo hello", timeoutSeconds: generous))])

        guard case .rendered(let expansion) = ExpansionRenderer()
            .render(snippet: snippet, transform: .none, context: context) else {
            Issue.record("expected a rendered expansion")
            return
        }
        // `"hello\n"` leaves the runner; the renderer is what makes it `"hello"` in the document.
        #expect(expansion.text == "hello!")
    }

    // MARK: Threads

    @Test("Runs from several threads at once do not cross their output")
    func isSafeFromSeveralThreadsAtOnce() {
        let collected = Collected()
        DispatchQueue.concurrentPerform(iterations: 8) { index in
            let output = (try? ShellRunner.run("echo \(index)", timeout: generous)) ?? "threw"
            collected.record(output, for: index)
        }
        #expect(collected.all == Dictionary(uniqueKeysWithValues: (0..<8).map { ($0, "\($0)\n") }))
    }
}

// MARK: - Helpers

/// Run outputs keyed by the thread that asked for them.
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int: String] = [:]

    func record(_ value: String, for index: Int) {
        lock.lock()
        defer { lock.unlock() }
        values[index] = value
    }

    var all: [Int: String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

/// Whether every process whose command line matches `pattern` is gone, polling until `seconds`
/// have passed. Polls rather than sleeps once, so the test is not a bet on how fast a signal lands.
private func waitForNoProcess(matching pattern: String, upTo seconds: Double) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    repeat {
        if !processExists(matching: pattern) { return true }
        usleep(50_000)
    } while Date() < deadline
    return !processExists(matching: pattern)
}

/// Kills anything whose command line matches `pattern`, so a failing test cleans up after itself.
private func killProcesses(matching pattern: String) {
    let pkill = Process()
    pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    pkill.arguments = ["-f", pattern]
    pkill.standardOutput = FileHandle.nullDevice
    pkill.standardError = FileHandle.nullDevice
    guard (try? pkill.run()) != nil else { return }
    pkill.waitUntilExit()
}

private func processExists(matching pattern: String) -> Bool {
    let pgrep = Process()
    pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    pgrep.arguments = ["-f", pattern]
    pgrep.standardOutput = FileHandle.nullDevice
    pgrep.standardError = FileHandle.nullDevice
    do { try pgrep.run() } catch { return false }
    pgrep.waitUntilExit()
    // pgrep exits 0 when it matched something, 1 when it matched nothing.
    return pgrep.terminationStatus == 0
}
