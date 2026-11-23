import Carbon.HIToolbox
import CoreGraphics
import Foundation
import WrdsKit

/// Watches every keystroke on the machine and reports it as a `KeyInput`.
///
/// This is the one place that turns hardware into the matcher's vocabulary. `TriggerMatcher` knows
/// only about characters, backspaces and resets; deciding which of the three a given key press is —
/// and which key presses are none of them — happens here and nowhere else.
///
/// ## Callbacks arrive on the tap's own thread. Not main. Ever.
///
/// The tap runs its own `CFRunLoop` on a dedicated thread, and `onKeyInput`,
/// `onBufferInvalidatingEvent` and `onTapDisabled` are called straight from the event callback on
/// that thread. **Anything a callback touches that belongs to the main actor has to be hopped to it
/// by the caller** — asynchronously, since a callback that blocks waiting on another thread parks
/// the tap.
///
/// The thread is not a detail to tidy away later. A session tap has a deadline: if the callback does
/// not return promptly the window server disables the tap outright
/// (`kCGEventTapDisabledByTimeout`), and the user's keyboard stops expanding until something notices
/// and re-enables it. On the main run loop that deadline is shared with every piece of UI work the
/// app does — a slow SwiftUI update, a modal panel, a spinning beachball anywhere — and each of them
/// becomes a way to lose the tap. Off it, the only thing that can miss the deadline is the work in
/// this file plus whatever the callbacks do.
///
/// Setting the three callbacks is therefore something to do *before* `start()`. They are plain
/// stored properties with no synchronisation, and writing one while the tap is live races the thread
/// reading it.
///
/// ## What it deliberately does not see
///
/// - **Its own typing.** `TextInjector` marks everything it posts with
///   `TextInjector.injectionSourceUserData`, and events carrying that mark are dropped here. Without
///   this an expansion containing a trigger expands forever.
/// - **Anything typed while secure input is on.** macOS raises `IsSecureEventInputEnabled()` around
///   password fields and the login window, and while it is up no event is inspected at all. The
///   buffer is invalidated instead, because keystrokes are going somewhere this app cannot see and a
///   buffer that pretends otherwise would splice what came before onto what comes after.
/// - **Modifier presses on their own.** Those arrive as `flagsChanged`, which is not in the mask.
///   A key press *with* ⌘ or ⌃ held is a different thing and is a reset, below.
///
/// ## Concurrency
///
/// `@unchecked Sendable` because this type exists to be reached from a C callback: the tap holds an
/// untyped pointer to `self` and calls into it from the tap thread, which is not something Swift can
/// check. What makes it true rather than merely asserted is that all mutable state — the tap, its
/// run loop source, and the moment the tap was last re-enabled — is guarded by `lock`, and the
/// callbacks are the caller's to make safe under the contract above.
final class KeystrokeMonitor: @unchecked Sendable {

    /// One keystroke, already translated. Called on the tap thread.
    var onKeyInput: ((KeyInput) -> Void)?

    /// The user clicked somewhere, so the caret is no longer where the typed characters were. Called
    /// on the tap thread.
    var onBufferInvalidatingEvent: (() -> Void)?

    /// The tap was disabled twice in quick succession and has been left off: expansion is over until
    /// something calls `start()` again, which retires the dead tap and installs a fresh one. Called
    /// on the tap thread.
    ///
    /// That retry must be made from somewhere else — hop to the main actor first. `start()` on a dead
    /// tap calls `stop()`, and `stop()` waits for this thread to unwind; calling it *from* this
    /// thread would be waiting on itself, and would spend the full teardown timeout doing it.
    var onTapDisabled: (() -> Void)?

    /// Virtual key codes, in the ANSI layout the window server speaks. Positions on the keyboard
    /// rather than characters, so they hold across layouts.
    private static let returnKeyCode: Int64 = 36
    private static let tabKeyCode: Int64 = 48
    private static let deleteKeyCode: Int64 = 51
    private static let escapeKeyCode: Int64 = 53
    /// Left, right, down, up.
    private static let arrowKeyCodes: ClosedRange<Int64> = 123...126

    /// How soon a second disable counts as "re-enabling did not help".
    private static let reEnableWindow: CFAbsoluteTime = 5

    /// How long `stop()` waits for the tap thread to finish tearing itself down. Only reachable if a
    /// callback broke the contract and blocked; a leaked thread beats a hang on quit.
    private static let teardownTimeout: DispatchTimeInterval = .seconds(2)

    /// Big enough for anything a single key press produces. `keyboardGetUnicodeString` reports the
    /// length it wanted, and the decode below clamps to what was actually written, so a longer
    /// sequence is truncated rather than read out of bounds.
    private static let unicodeBufferLength = 16

    /// Guards everything below it. Held only for the length of a field read or write — never across a
    /// callback, and never across a call into CoreGraphics.
    private let lock = NSLock()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    /// When the tap was last re-enabled after being disabled, or `nil` if it has not been.
    private var lastReEnable: CFAbsoluteTime?
    /// Set by `stop()` before it stops the run loop, so the thread can tell an exit it was asked for
    /// from one it was not.
    private var shouldStop = false
    /// Whether the tap has been given up on — set when `onTapDisabled` fires, or when the run loop
    /// ends without being asked to. The tap is still installed but is no longer delivering, so
    /// `start()` must rebuild rather than report success on the strength of it being non-`nil`.
    private var isDead = false

    /// Signalled once the tap thread's run loop is **running**, which is a stronger thing than the
    /// thread having started and is the whole point of it.
    ///
    /// `CFRunLoopStop` does nothing at all to a run loop that is not currently running — it checks
    /// `_currentMode` and returns. So if `start()` were allowed to return once the thread merely
    /// existed, a `stop()` immediately afterwards could fire into the gap before `CFRunLoopRun()`,
    /// be dropped on the floor, and leave the thread running forever with `stop()` reporting success.
    /// The signal is therefore emitted from *inside* the loop, by a block the thread queues before
    /// entering it (see `runTapLoop`).
    private let running = DispatchSemaphore(value: 0)

    /// Signalled once the tap thread has torn everything down and is about to exit.
    ///
    /// One per run rather than one per monitor, so that a `stop()` which gave up waiting cannot leave
    /// a signal behind for the *next* run's `stop()` to consume and return early on. The thread
    /// captures the instance belonging to its own run; `stop()` waits on whichever is current.
    private var stopped: DispatchSemaphore?

    /// Installs the tap and starts watching.
    ///
    /// - Returns: `false` if the tap could not be created, which in practice means one thing:
    ///   Input Monitoring has not been granted. There is no error to report — `tapCreate` simply
    ///   hands back `nil` — so this Boolean *is* the permission signal, and the caller's job is to
    ///   ask `PermissionsChecker` why and say so. `true` if the tap is live, including when it was
    ///   already live from an earlier call. A tap that `onTapDisabled` gave up on does not count as
    ///   live: this retires it and builds another, so calling `start()` again is the retry.
    ///
    /// Call from one thread — the main one — and pair every `true` with a `stop()`. A running monitor
    /// holds a strong reference to itself through its thread and cannot be deallocated until then;
    /// that is deliberate, because the tap callback reaches `self` through an unretained pointer and
    /// a monitor that could be released out from under a live tap would be a use-after-free on the
    /// next keystroke.
    func start() -> Bool {
        lock.lock()
        let installed = tap != nil
        let dead = isDead
        lock.unlock()
        // A tap that is installed and still delivering needs nothing doing. One that has been given
        // up on is worse than no tap, because it looks like a working one: retire it first, so what
        // follows builds a live replacement instead of reporting success on a corpse.
        if installed, !dead { return true }
        if installed { stop() }

        guard let tap = makeTap() else { return false }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }

        lock.lock()
        self.tap = tap
        self.source = source
        stopped = DispatchSemaphore(value: 0)
        lastReEnable = nil
        shouldStop = false
        isDead = false
        lock.unlock()

        let thread = Thread { [self] in runTapLoop() }
        thread.name = "com.fwrds.keystroke-monitor"
        // The window server's deadline is the reason this thread exists; it should not be waiting
        // behind background work for a core.
        thread.qualityOfService = .userInteractive
        thread.start()
        running.wait()
        return true
    }

    /// Takes the tap down and does not return until it is gone.
    ///
    /// Disabling comes first so no further events can be delivered, then the run loop is stopped and
    /// the thread invalidates the source and the port on its way out — teardown happens on the thread
    /// that owns them, so it can never race a callback in flight.
    ///
    /// Safe to call when nothing is running, and safe to call twice.
    func stop() {
        lock.lock()
        let tap = self.tap
        let runLoop = self.runLoop
        let stopped = self.stopped
        // Set before the loop is stopped, so the thread cannot see the stop without also seeing the
        // reason for it.
        shouldStop = true
        lock.unlock()
        guard let tap, let runLoop, let stopped else { return }

        CGEvent.tapEnable(tap: tap, enable: false)
        // Guaranteed to land, because `start()` did not return until the loop was genuinely running
        // and only this call ends it — see the note on `running`.
        CFRunLoopStop(runLoop)
        guard stopped.wait(timeout: .now() + Self.teardownTimeout) == .timedOut else { return }

        // Only reachable if a callback is still blocked somewhere it should not be. The thread will
        // finish its own cleanup whenever it is unblocked — it checks that the tap it is retiring is
        // still the current one before clearing anything — so releasing these here is what lets a
        // later `start()` build a fresh tap rather than believing this one is still good.
        lock.lock()
        if self.tap === tap {
            self.tap = nil
            self.source = nil
            self.runLoop = nil
            self.stopped = nil
            lastReEnable = nil
        }
        lock.unlock()
    }

    // MARK: The tap

    /// Creates the session tap, or returns `nil` when Input Monitoring has not been granted.
    private func makeTap() -> CFMachPort? {
        let mask =
            CGEventMask(1) << CGEventType.keyDown.rawValue
            | CGEventMask(1) << CGEventType.leftMouseDown.rawValue
            | CGEventMask(1) << CGEventType.rightMouseDown.rawValue

        return CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            // Listen-only, so the tap can never delay or swallow a keystroke: the window server
            // hands the event on regardless of what this callback does. It also asks for the weaker
            // of the two grants — Input Monitoring rather than Accessibility.
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                if let context {
                    Unmanaged<KeystrokeMonitor>.fromOpaque(context)
                        .takeUnretainedValue()
                        .handle(type, event)
                }
                // A listen-only tap's return value is ignored. The event is handed back unchanged
                // because the signature insists on one.
                return Unmanaged.passUnretained(event)
            },
            // Unretained: the monitor outlives its tap by construction — the thread holds it, and
            // only `stop()` lets go. Retaining here would instead mean nothing could ever release it.
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
    }

    /// The tap thread: registers the source, runs the loop, and cleans up once `stop()` ends it.
    private func runTapLoop() {
        lock.lock()
        let tap = self.tap
        let source = self.source
        // This run's own semaphore, held locally: if `stop()` gives up waiting and another `start()`
        // replaces it, this thread must still signal the one whoever is waiting is holding.
        let stopped = self.stopped
        let runLoop = CFRunLoopGetCurrent()
        self.runLoop = runLoop
        lock.unlock()

        // Unreachable as things stand — `start()` fills both in before starting this thread — but
        // leaving without signalling would cost a waiting `stop()` the full teardown timeout.
        guard let tap, let source else {
            running.signal()
            stopped?.signal()
            return
        }

        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        // Announce readiness from *inside* the loop rather than here. A block queued now is run by
        // `CFRunLoopRun()` on its first pass, by which point the loop has set `_currentMode` — which
        // is the exact condition `CFRunLoopStop` requires in order to do anything. Signalling on this
        // line instead would let `start()` return while the loop was still being entered, and a
        // `stop()` landing in that window would be silently discarded, leaving this thread, its tap,
        // its mach port and the monitor itself alive forever while `stop()` reported success.
        //
        // The wake-up is belt and braces: the loop is not asleep yet, and processes queued blocks as
        // it starts regardless.
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { [self] in
            running.signal()
        }
        CFRunLoopWakeUp(runLoop)

        // Returns only when `stop()` calls `CFRunLoopStop`: the source keeps the loop alive, and
        // `_currentMode` stays set for the whole of this one call, so no stop can be missed.
        CFRunLoopRun()

        CFRunLoopRemoveSource(runLoop, source, .commonModes)
        CFRunLoopSourceInvalidate(source)
        CFMachPortInvalidate(tap)

        lock.lock()
        // A loop that ended without `stop()` asking has lost its source somehow; the tap is gone
        // either way, and saying so is what stops the next `start()` believing this one still works.
        if !shouldStop { isDead = true }
        // Checked rather than assumed: if `stop()` gave up waiting and a fresh `start()` has since
        // installed another tap, those fields describe the new one and are not this thread's to clear.
        if self.tap === tap {
            self.tap = nil
            self.source = nil
            self.runLoop = nil
            self.stopped = nil
            lastReEnable = nil
        }
        lock.unlock()
        stopped?.signal()
    }

    // MARK: Events

    /// The event callback's Swift half. Runs on the tap thread.
    private func handle(_ type: CGEventType, _ event: CGEvent) {
        // Both disable notifications arrive whatever the mask asked for, and carry no key or mouse
        // information — so they are answered before anything tries to read the event as one.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            handleTapDisabled()
            return
        }

        // The app's own injection is not the user typing. Dropping it is what stops an expansion
        // whose replacement contains a trigger from expanding itself forever.
        let userData = event.getIntegerValueField(.eventSourceUserData)
        guard userData != TextInjector.injectionSourceUserData else { return }

        // Secure input: a password field, or the login window. Nothing about the event is read —
        // not the key code, not the characters. The buffer is invalidated rather than merely left
        // alone, because characters are being typed that this app cannot see, and a buffer that
        // survived them would join what was typed before the password to what is typed after.
        guard !IsSecureEventInputEnabled() else {
            onBufferInvalidatingEvent?()
            return
        }

        switch type {
        case .keyDown:
            translate(event)
        case .leftMouseDown, .rightMouseDown:
            // The caret has moved somewhere this app has no way to follow.
            onBufferInvalidatingEvent?()
        default:
            break
        }
    }

    /// Turns one key press into a `KeyInput`, or into nothing at all.
    private func translate(_ event: CGEvent) {
        let flags = event.flags
        // ⌘ and ⌃ make a keystroke a command rather than text — ⌘A, ⌃E, ⌘← — and every one of them
        // either moves the caret or replaces what is around it. ⌥ deliberately does not qualify:
        // option-typed characters (é, ñ, œ) are ordinary text and arrive as printable unicode below.
        guard !flags.contains(.maskCommand), !flags.contains(.maskControl) else {
            onKeyInput?(.reset)
            return
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if keyCode == Self.deleteKeyCode {
            // ⌥⌫ deletes a whole word, not a character, and there is no way to know how long that
            // word was in the app receiving it. One backspace off the buffer would leave it claiming
            // characters the document no longer holds, so the honest answer is to forget everything.
            onKeyInput?(flags.contains(.maskAlternate) ? .reset : .backspace)
            return
        }
        if keyCode == Self.returnKeyCode || keyCode == Self.tabKeyCode || keyCode == Self.escapeKeyCode
            || Self.arrowKeyCodes.contains(keyCode) {
            onKeyInput?(.reset)
            return
        }

        var length = 0
        var buffer = [UniChar](repeating: 0, count: Self.unicodeBufferLength)
        event.keyboardGetUnicodeString(
            maxStringLength: buffer.count,
            actualStringLength: &length,
            unicodeString: &buffer
        )

        // A dead key — ⌥E on its way to é — produces no characters at all. Nothing is emitted for it;
        // the composed character arrives on the *next* key press, as a single ordinary `.character`,
        // which is exactly what the buffer should see.
        guard length > 0 else { return }
        let typed = String(utf16CodeUnits: buffer, count: min(length, buffer.count))

        // Home, End, Page Up, Page Down, forward delete and the function keys are not in the key-code
        // list above, and they all produce control characters or private-use scalars rather than
        // text. Most of them move the caret, so they are resets; none of them is something to put in
        // a buffer of what the user typed.
        guard typed.unicodeScalars.allSatisfy(Self.isTextual) else {
            onKeyInput?(.reset)
            return
        }

        // One key press can carry several characters — a surrogate pair, or an input method
        // committing a sequence — so the string is walked by `Character` rather than assumed to be
        // one.
        for character in typed {
            onKeyInput?(.character(character))
        }
    }

    /// Whether a scalar is text, as opposed to a key that happens to have a code point.
    private static func isTextual(_ scalar: Unicode.Scalar) -> Bool {
        // C0 controls, then DEL and the C1 block above it — U+0080…U+009F are controls too, and no
        // key on a keyboard produces one as text — then the private-use block macOS uses for arrows,
        // function keys, Home and the rest (`NSUpArrowFunctionKey` and friends live at U+F700 and up).
        scalar.value >= 0x20
            && !(0x7F...0x9F).contains(scalar.value)
            && !(0xF700...0xF8FF).contains(scalar.value)
    }

    /// Answers `kCGEventTapDisabledByTimeout` / `…ByUserInput`. Runs on the tap thread.
    ///
    /// The window server disables a tap whose callback took too long, and also when the user presses
    /// the keys that force it to (which is how a wedged tap is escaped). A single re-enable covers
    /// the ordinary case — a machine that stalled once under load — and costs nothing.
    ///
    /// Being disabled *again* within `reEnableWindow` of that re-enable means retrying is not
    /// working, so the tap is left off and `onTapDisabled` says so. Retrying past that point would
    /// spin against the window server while the user's typing quietly failed to expand; better to
    /// stop and let the app show something.
    private func handleTapDisabled() {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        let tap = self.tap
        let giveUp = lastReEnable.map { now - $0 < Self.reEnableWindow } ?? false
        if giveUp {
            // The tap stays installed but stops delivering, so a later `start()` would otherwise see
            // a non-`nil` tap and report a working monitor that never fires again.
            isDead = true
        } else {
            lastReEnable = now
        }
        lock.unlock()

        guard let tap else { return }
        if giveUp {
            onTapDisabled?()
        } else {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }
}
