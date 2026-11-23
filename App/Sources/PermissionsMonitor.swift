import Foundation
import Observation

/// Polls `PermissionsChecker` once a second so onboarding's grant indicators track System Settings
/// live.
///
/// Input Monitoring has no programmatic prompt for a listen-only tap — see `PermissionsChecker`'s own
/// doc comment — so the user flips a switch in System Settings by hand, in a different process, and
/// nothing tells this one when they do. Polling while onboarding is on screen is how the indicator
/// turns green the moment they do it. Nowhere else in the app polls: `AppModel.recheckEngine()`
/// re-checks only when the app becomes active again, which is the cheap approximation everywhere a
/// user is not expected to be sitting mid-grant, watching for it.
///
/// `start()`/`stop()` are explicit rather than tied to `init`/`deinit` so one instance can be reused
/// across an onboarding session: `OnboardingView` starts it once, when its window appears, and stops
/// it once, when the window closes — see that view's `onAppear`/`onDisappear`.
@MainActor
@Observable
final class PermissionsMonitor {
    private(set) var hasAccessibility = PermissionsChecker.hasAccessibility
    private(set) var hasInputMonitoring = PermissionsChecker.hasInputMonitoring

    private var timer: Timer?

    /// Begins polling, taking an immediate reading first so the indicators are already correct before
    /// the first tick arrives a second later. Safe to call while already running — a second call is a
    /// no-op rather than a second timer racing the first.
    ///
    /// Scheduled on the main run loop's `.common` mode rather than the default
    /// `Timer.scheduledTimer(withTimeInterval:repeats:block:)`, which uses `.default`: `.default` mode
    /// timers pause while the run loop is tracking a mouse-down inside this very window — clicking and
    /// holding "Grant…" would otherwise freeze the indicators for as long as the button is held.
    func start() {
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Stops polling. Called when onboarding's window closes, so nothing keeps reading TCC/IOHID state
    /// once there is nothing on screen to show it changing.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        hasAccessibility = PermissionsChecker.hasAccessibility
        hasInputMonitoring = PermissionsChecker.hasInputMonitoring
    }
}
