import Foundation
import ServiceManagement

/// What `GeneralSettingsView` needs from a login item — narrow enough to fake, the same shape
/// `hosts-switchr` uses for the same reason: a settings view that talks to a protocol rather than
/// `SMAppService` directly is a settings view a future test double could drive without touching the
/// real login-item registry. (F Wrds has no App-layer test target yet — see the other files' notes on
/// that gap — so nothing exercises the fake today; the seam is here anyway, at no extra cost.)
protocol LoginItemControlling {
    var isEnabled: Bool { get }
    func enable() throws
    func disable() throws
}

/// `SMAppService.mainApp` registers *this app bundle* as a login item — no separate signed helper
/// tool. That matters here: F Wrds is unsigned (`CODE_SIGNING_REQUIRED: NO` in `project.yml`), and a
/// helper-based login item needs a signed, embedded launcher `SMAppService` can validate before it
/// will register it. Registering the main app itself carries no such requirement — it is the one
/// login-item flavour available to an ad-hoc-signed, unsigned-distribution build.
///
/// Adapted verbatim from `hosts-switchr`'s `SMAppServiceLoginItem` — the same one-app, same-constraint
/// shape applies unchanged.
struct SMAppServiceLoginItem: LoginItemControlling {
    var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    func enable() throws { try SMAppService.mainApp.register() }
    func disable() throws { try SMAppService.mainApp.unregister() }
}

/// Applies a desired login-item state and reports what actually happened.
///
/// `SMAppService.register()`/`unregister()` both throw — in practice when the user has turned off
/// "Allow in the Background" for this app in System Settings, or on first registration before the app
/// has ever been approved there — so the toggle the user just clicked cannot simply assume the click
/// worked. `apply` always re-reads `item.isEnabled` after attempting the change, on both the success
/// and the failure path, so the caller's control snaps back to whatever the system actually has rather
/// than to the state the user clicked towards.
enum LaunchAtLogin {
    static func apply(_ desired: Bool, to item: LoginItemControlling) -> (isEnabled: Bool, error: String?) {
        do {
            if desired { try item.enable() } else { try item.disable() }
            return (item.isEnabled, nil)
        } catch {
            let message = desired
                ? String(localized: "Couldn't enable launch at login: \(error.localizedDescription)")
                : String(localized: "Couldn't disable launch at login: \(error.localizedDescription)")
            return (item.isEnabled, message)
        }
    }
}
