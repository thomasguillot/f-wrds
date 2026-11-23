import AppKit
import ApplicationServices
import IOKit.hid

/// The two macOS grants F Wrds cannot work without, and the two places a person goes to give them.
///
/// **Nothing calls any of this at launch, and nothing may until onboarding exists.** Both of the
/// functions below put a system panel in front of whoever is at the keyboard — one an Accessibility
/// prompt, one System Settings — and a permission prompt that arrives before the app has said what
/// it is for gets refused. Task 17's onboarding is the only intended caller; the two properties are
/// safe to read at any time, but the app has nowhere to show their answer yet either.
///
/// The two grants are separate, neither implies the other, and they fail in different ways:
///
/// - **Input Monitoring** is what `CGEvent.tapCreate` needs. Without it `tapCreate` returns `nil`,
///   which is the whole of `KeystrokeMonitor.start()` returning `false`. So the monitor reports its
///   own permission failure, and `hasInputMonitoring` is only needed to *explain* it.
/// - **Accessibility** is what posting events into another app needs — everything `TextInjector`
///   does. Without it events are created and posted with no error whatsoever and simply never
///   arrive. There is no failure to observe, which is why this has to be checked up front rather
///   than inferred from an expansion that did not appear.
///
/// Both grants are recorded against the app's code signature and its path. An unsigned development
/// build re-copied to a new location is, to TCC, a different app: the grant does not follow it and
/// the old entry has to be removed by hand. Worth knowing before reading a `false` here as a bug.
///
/// Safe to call from any thread.
enum PermissionsChecker {

    /// Whether this process may drive other apps — post keyboard events into them, in F Wrds' case.
    ///
    /// Reads the current answer without prompting, so it is safe to poll (onboarding does, to notice
    /// the moment the user grants it in System Settings).
    static var hasAccessibility: Bool {
        AXIsProcessTrusted()
    }

    /// Whether this process may observe keyboard events belonging to other apps.
    ///
    /// `kIOHIDRequestTypeListenEvent` is the listen-only side of Input Monitoring, which is all a
    /// `.listenOnly` event tap needs; the post side is Accessibility's business, above. Like
    /// `hasAccessibility` this only reads — `IOHIDRequestAccess` is the one that prompts, and F Wrds
    /// deliberately does not call it: the Input Monitoring prompt cannot be re-shown once dismissed,
    /// so onboarding sends people to Settings instead, where the switch is always there to flip.
    static var hasInputMonitoring: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Asks for Accessibility, showing the system's "F Wrds would like to control this computer"
    /// panel if the answer is not already yes.
    ///
    /// Returns immediately and tells the caller nothing: the panel is the *system's*, the user
    /// answers it in System Settings at their own pace, and the process is not notified when they
    /// do. Poll `hasAccessibility` to find out.
    ///
    /// The key is spelled out rather than read from `kAXTrustedCheckOptionPrompt` because that
    /// constant is imported from C as a mutable global, which Swift 6 refuses to touch from
    /// concurrency-checked code. Nothing here reads it at runtime: the literal was checked against
    /// the constant's value in the macOS 26.5 SDK when it was written, rather than recalled, and it
    /// is a documented part of the Accessibility API that will not change under it.
    static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        // The return value is the same thing `hasAccessibility` reads, and is stale the moment the
        // panel appears — whether the user then says yes is what polling is for.
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Opens System Settings on Privacy & Security ▸ Input Monitoring, with F Wrds in the list.
    ///
    /// There is no API to *request* Input Monitoring twice: the system prompt is offered once, and a
    /// user who dismissed it has no way back except this pane. Sending them straight to it is the
    /// whole recovery path, so onboarding shows this rather than a prompt in the first place.
    static func openInputMonitoringSettings() {
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
            )
        else { return }
        // The result only says whether an app was found to open the URL; there is nothing useful to
        // do with a `false` beyond what the user can already see, which is Settings not opening.
        _ = NSWorkspace.shared.open(url)
    }
}
