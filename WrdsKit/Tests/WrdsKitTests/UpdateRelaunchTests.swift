import Testing
@testable import WrdsKit

@Suite struct UpdateRelaunchTests {
    @Test func embedsPidAndPath() {
        let script = UpdateRelaunch.shellScript(pid: 4242, appPath: "/Applications/F Wrds.app")
        #expect(script.contains("4242"))
        #expect(script.contains("/Applications/F Wrds.app"))
    }

    @Test func waitsForOldInstanceThenOpens() {
        let script = UpdateRelaunch.shellScript(pid: 7, appPath: "/Applications/F Wrds.app")
        // Poll the dying PID before launching: a fixed sleep races teardown.
        #expect(script.contains("/bin/kill -0 7"))
        #expect(script.contains("/usr/bin/open"))
        // The open must come after the wait loop, not before.
        let killIndex = script.range(of: "/bin/kill -0 7")!.lowerBound
        let openIndex = script.range(of: "/usr/bin/open")!.lowerBound
        #expect(killIndex < openIndex)
    }

    @Test func waitIsBounded() {
        // A wedged old process must not stall the relaunch forever.
        let script = UpdateRelaunch.shellScript(pid: 1, appPath: "/Applications/F Wrds.app")
        #expect(script.contains("-lt 150"))
    }

    @Test func pathIsQuoted() {
        // The real installed path — /Applications/F Wrds.app, matching the "F Wrds" display name —
        // already contains a space, which is exactly what this proves the quoting survives. A
        // distinct synthetic name here just isolates the quoting mechanism from that specific value.
        let script = UpdateRelaunch.shellScript(pid: 1, appPath: "/Applications/FWrds Beta.app")
        #expect(script.contains("'/Applications/FWrds Beta.app'"))
    }

    @Test func pathCannotBreakOutOfItsQuoting() {
        // Single quotes, not double, because a `$` or a backtick inside double quotes is still
        // shell syntax — the failure being prevented is not a relaunch that misses, it is
        // arbitrary shell running as the user.
        let script = UpdateRelaunch.shellScript(pid: 1, appPath: "/tmp/$(touch pwned).app")
        #expect(script.hasSuffix("'/tmp/$(touch pwned).app'"))

        // The one character single quotes cannot hold, spliced back in rather than dropped.
        let awkward = UpdateRelaunch.shellScript(pid: 1, appPath: "/tmp/it's here.app")
        #expect(awkward.hasSuffix(#"'/tmp/it'\''s here.app'"#))
    }
}
