import Foundation
import WrdsKit

/// Where `ExpansionEngine` gets its keystrokes from: `KeystrokeMonitor` in the app.
///
/// The contract is `KeystrokeMonitor`'s, and a conformer has to keep all of it. The three callbacks
/// are set once, before `start()`, and never again; they arrive on the source's own thread, and the
/// engine answers each by hopping to its own queue and returning. `start()` and `stop()` are called
/// from the main actor, and `stop()` is safe to call twice.
protocol KeystrokeSource: AnyObject, Sendable {
    var onKeyInput: ((KeyInput, _ fromAnotherApp: Bool) -> Void)? { get set }
    var onBufferInvalidatingEvent: (() -> Void)? { get set }
    var onTapDisabled: (() -> Void)? { get set }
    func start() -> Bool
    func stop()
}

extension KeystrokeMonitor: KeystrokeSource {}

/// How `ExpansionEngine` puts text in front of the caret: `TextInjector` in the app.
///
/// Every method is called from the engine's serial queue, in the order the expansion needs, and must
/// be safe to call from there — which for `TextInjector` means never from the tap thread. See
/// `TextInjector` for what each call does to the frontmost app and to the clipboard.
protocol TextInjecting: AnyObject, Sendable {
    func deleteCharacters(_ count: Int)
    func paste(_ text: String, restoreClipboardAfter delay: TimeInterval)
    func typeText(_ text: String)
    func pressArrowLeft(times: Int)
    func clipboardText() -> String?
}

extension TextInjector: TextInjecting {}
