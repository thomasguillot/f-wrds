import Carbon.HIToolbox
import Foundation
import WrdsKit

/// Wraps Carbon's `RegisterEventHotKey` — the only API on macOS that can claim a global keyboard
/// shortcut and have the *system* consume it before it ever reaches whichever app is frontmost,
/// without this app running an event tap positioned to swallow keystrokes of its own.
///
/// ## Why Carbon, and why not the tap this app already has
///
/// `RegisterEventHotKey` has been technically deprecated for a long time and Apple has shipped
/// nothing in its place; it remains what System Settings' own "Keyboard Shortcuts" pane and most
/// third-party launchers are built on, because nothing else lets a background app claim one
/// combination and have the window server withhold it from every other app's frontmost window.
///
/// F Wrds does have a `CGEventTap` — `KeystrokeMonitor` — but it is `.listenOnly` by design: it
/// watches every keystroke on the machine to feed the trigger matcher, and a listen-only tap cannot
/// also decide to swallow one. Making it consuming so it could claim ⌥Space itself would mean every
/// key press on the machine passes through this app's callback with the power to withhold it from
/// its destination — a far bigger footprint than "watch and report", and the one callback that runs
/// slow or gets stuck for a moment would eat a keystroke system-wide rather than merely miss a
/// trigger. `RegisterEventHotKey` asks the window server to do the consuming instead, scoped to
/// exactly the one combination registered, which is the smaller and safer capability for what a
/// global hotkey actually needs.
///
/// ## Threading
///
/// Every stored property here is main-actor state, and Carbon delivers the hotkey-pressed event on
/// the same run loop `NSApplication` runs — `GetApplicationEventTarget()` hooks directly into the
/// process's default run loop rather than running one of its own, so the callback below is already on
/// the main thread in practice. It still hops on with `Task { @MainActor in }` rather than
/// `MainActor.assumeIsolated`, though, because the Swift 6 compiler cannot see that guarantee: the
/// callback is a plain C function with no actor context of its own, and its `UnsafeMutableRawPointer`
/// parameter is flagged as unsafe to hand straight into a synchronous main-actor closure (Swift's
/// region-based isolation checking cannot prove the parameter is not read again from the nonisolated
/// side afterwards). Wrapping the one line that needs `self` in a `Task` sidesteps that: the pointer
/// is unwrapped inside the task, once it is unambiguously running on the main actor, rather than
/// carried across the boundary as an argument.
@MainActor
final class HotKeyCenter {
    /// `"FWRD"` in ASCII — the same marker `TextInjector` stamps on its own events, reused here as
    /// this app's Carbon hotkey signature. It only has to be unique among *this process's*
    /// registrations (Carbon scopes hotkey IDs by the target they were registered on), so any four
    /// bytes would do; this one is recognisably F Wrds' own if anyone goes looking.
    fileprivate static let signature: OSType = 0x46_57_52_44

    /// `nonisolated(unsafe)` on these two, and not on `handlers`: `deinit` is never main-actor
    /// isolated in Swift, even for a `@MainActor` class, so it cannot touch ordinary actor-isolated
    /// storage to release these two Carbon handles on the way out. That is safe in fact rather than
    /// merely asserted — by the time `deinit` runs there are no other references left to `self` and
    /// therefore no possible concurrent access to race — but the compiler cannot see that invariant,
    /// which is exactly what `nonisolated(unsafe)` is for. `handlers` is never read from `deinit`, so
    /// it keeps the compiler's normal main-actor checking on every other access.
    private nonisolated(unsafe) var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private nonisolated(unsafe) var eventHandlerRef: EventHandlerRef?

    /// Whether `InstallEventHandler` actually succeeded. Checked because a hotkey "registered" with
    /// no handler installed to catch its `kEventHotKeyPressed` would never fire — `RegisterEventHotKey`
    /// itself would report success, and the failure would be silent from every caller's point of view.
    /// `register(_:id:handler:)` refuses to proceed without this, which is what turns "the event
    /// handler never installed" into the same `false` return every other registration failure already
    /// produces, and from there into `AppModel.reregisterHotKeys()`'s existing `hotKeyFailure` text —
    /// no separate reporting path needed.
    private var isEventHandlerInstalled = false

    init() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(), hotKeyCenterCallback, 1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(), &eventHandlerRef)
        isEventHandlerInstalled = status == noErr
    }

    deinit {
        for ref in hotKeyRefs.values { UnregisterEventHotKey(ref) }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
    }

    /// Claims `spec` as a global hotkey that calls `handler` when pressed, replacing whatever was
    /// registered under `id` before — safe to call again for the same `id` when the user picks a new
    /// combination. `handler` runs on the main actor, the same as every other entry point into
    /// `AppModel`.
    ///
    /// - Returns: `false` when the window server refused the registration — in practice, either this
    ///   exact combination is already claimed by another app, or (per Carbon's own contract) by a
    ///   *different* `id` in this same process — or when `isEventHandlerInstalled` is `false`, in
    ///   which case nothing was even attempted: registering a hotkey nothing can ever catch would be
    ///   worse than refusing, since it would report success and then simply never fire. Nothing is
    ///   left registered under `id` either way, so the caller never has to unregister after a failed
    ///   call.
    @discardableResult
    func register(_ spec: HotKeySpec, id: UInt32, handler: @escaping () -> Void) -> Bool {
        unregister(id: id)
        guard isEventHandlerInstalled else { return false }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(
            spec.keyCode, spec.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        hotKeyRefs[id] = ref
        handlers[id] = handler
        return true
    }

    /// Releases whatever is registered under `id`. Safe to call when nothing is — including from
    /// `register(_:id:handler:)`, which always calls this first.
    func unregister(id: UInt32) {
        if let ref = hotKeyRefs.removeValue(forKey: id) {
            UnregisterEventHotKey(ref)
        }
        handlers.removeValue(forKey: id)
    }

    /// Runs the handler registered for `id`. Called only from `hotKeyCenterCallback`, which has
    /// already hopped onto the main actor by the time this is reached.
    fileprivate func fire(id: UInt32) {
        handlers[id]?()
    }
}

/// The C half of the Carbon callback: reads which hotkey fired out of the event and hops onto the
/// `HotKeyCenter` that installed it.
///
/// A free function rather than a closure literal, so there is no question about it being convertible
/// to the `@convention(c)` function pointer `InstallEventHandler` asks for — it captures nothing, the
/// one thing a C function pointer cannot do. `userData` is how the specific `HotKeyCenter` instance
/// gets here at all: Carbon has no notion of "self", so `init()` hands this function the same opaque
/// pointer back through `InstallEventHandler`'s own `inUserData` parameter.
private func hotKeyCenterCallback(
    _ nextHandler: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr else { return status }
    let id = hotKeyID.id
    // The `Unmanaged` unwrap happens out here, synchronously — it is only a pointer cast, nothing
    // about it needs the main actor. What crosses into the `Task` below is `center`, a freshly bound
    // local with exactly one later use, which is what lets the compiler treat it as legitimately
    // `sending` even though `HotKeyCenter` is not itself `Sendable`. Capturing `userData` (the
    // function *parameter*) directly instead does not have that property — the region checker cannot
    // rule out another nonisolated use of a parameter the same way it can for a local — and that is
    // the difference between this and the version that failed to compile.
    let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
    Task { @MainActor in
        center.fire(id: id)
    }
    return noErr
}

extension HotKeySpec {
    /// How this combination reads in a menu — the modifiers as their standard glyphs, always in the
    /// system's own ⌃⌥⇧⌘ order, then the key itself.
    ///
    /// **ANSI-US only, and that is a known, accepted limit.** `keyCode` is a position on the
    /// keyboard, not a character — 49 is labelled "Space" on every layout, but a letter key's label
    /// depends on the layout in front of the user, and doing that properly means translating through
    /// `UCKeyTranslate` and the *current* keyboard layout, the way System Settings' own recorder
    /// does. That belongs with Task 18's shortcut recorder, which has to solve the harder half of the
    /// same problem anyway (turning a key someone just pressed back into a label as they watch); this
    /// is only ever asked to describe the one hotkey this build can produce today — the shipped ⌥Space
    /// default — so a small fixed table for the keys anyone would plausibly bind is enough for now.
    var displayString: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        result += Self.keyLabels[keyCode] ?? "Key \(keyCode)"
        return result
    }

    /// ANSI-US virtual key codes → their printed label, for letters, digits, space, and the named
    /// editing/navigation keys.
    private static let keyLabels: [UInt32: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J",
        40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T",
        32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 53: "Escape",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
}
