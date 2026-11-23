import AppKit
import Carbon.HIToolbox
import SwiftUI
import WrdsKit

/// Click-to-record control for one `HotKeySpec?` setting. `ExpansionSettingsView` uses two of these —
/// the picker and pause hotkeys — differing only in whether ⌫ is allowed to clear the value and what
/// the *other* hotkey currently is, so the two can never be recorded onto the same combination.
///
/// Recording installs a **local** `NSEvent` monitor (`.keyDown`) rather than reaching for
/// `HotKeyCenter`'s global Carbon registration: this only ever needs to see keys typed while this
/// window is key, and a local monitor is the ordinary, low-footprint way to do that. Nothing here
/// competes with whatever combination `HotKeyCenter` already has registered globally — the recorded
/// spec is only handed to `AppModel` (via the caller's `Binding`) once recording finishes, and
/// `AppModel.update(_:)` is what re-registers it for real.
struct HotKeyRecorderView: View {
    let label: LocalizedStringKey
    @Binding var value: HotKeySpec?
    /// Whether ⌫ clears the value while recording. Offered for the pause hotkey, which is optional
    /// by design (`AppSettings.pauseHotKey: HotKeySpec?` with no default). Refused for the picker
    /// hotkey: once it is cleared, the menu-bar "Open Picker…" item is the only way left to reach the
    /// picker at all, and that is a worse trap to fall into by an accidental ⌫ than the inconvenience
    /// of always requiring a combination here.
    let allowsClearing: Bool
    /// The other hotkey's current value, if any. `HotKeyCenter.register(_:id:handler:)` only allows
    /// one registration per combination per process — Carbon's own rule — so recording this one onto
    /// the same combination would leave whichever registered first working and the other silently
    /// reported via `AppModel.hotKeyFailure`. Refusing the collision here, before it can ever reach
    /// that state, is cheaper for the user to understand than a status line explaining it after the
    /// fact.
    var conflictsWith: HotKeySpec?

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var message: String?

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Button(action: toggleRecording) {
                    Text(buttonTitle)
                        .frame(minWidth: 120)
                }
                .buttonStyle(.bordered)
                .tint(isRecording ? .accentColor : nil)
                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private var buttonTitle: String {
        if isRecording { return String(localized: "Press Shortcut\u{2026}") }
        return value?.displayString ?? String(localized: "Click to set")
    }

    private func toggleRecording() {
        if isRecording {
            stopRecording()
            message = nil
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        message = allowsClearing
            ? String(localized: "Press a shortcut. Esc cancels, ⌫ clears.")
            : String(localized: "Press a shortcut. Esc cancels.")
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            // Swallowed either way: a key pressed while recording is never meant to also reach
            // whatever field would otherwise have focus behind this one.
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }

    private func handle(_ event: NSEvent) {
        if Int(event.keyCode) == kVK_Escape {
            stopRecording()
            message = nil
            return
        }
        if allowsClearing, Int(event.keyCode) == kVK_Delete,
           Self.carbonModifiers(event.modifierFlags) == 0 {
            value = nil
            stopRecording()
            message = nil
            return
        }
        let modifiers = Self.carbonModifiers(event.modifierFlags)
        guard modifiers != 0 else {
            // A bare key claimed as a *global* hotkey would hijack ordinary typing the instant it is
            // pressed in any app, anywhere — there is no "only while F Wrds means it" — so this
            // recorder refuses one outright rather than registering something the user almost
            // certainly did not mean to give up their own "e" key for.
            message = String(localized: "Shortcuts need at least one modifier key (⌘⌥⌃⇧).")
            return
        }
        let spec = HotKeySpec(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        guard spec != conflictsWith else {
            message = String(localized: "You've already used that combination for the other shortcut.")
            return
        }
        value = spec
        stopRecording()
        message = nil
    }

    /// `NSEvent.ModifierFlags` → the Carbon mask `HotKeySpec`/`RegisterEventHotKey` want. Only the
    /// four a user can actually chord are honoured — `.capsLock`/`.function`/`.numericPad` etc. are
    /// not shortcut modifiers and are dropped rather than folded in as noise.
    private static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        return result
    }
}
