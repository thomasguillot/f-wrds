import Foundation

/// Fires one background update check shortly after launch, respecting `settings
/// .checkForUpdatesAutomatically`. Reads the live setting from `AppModel` rather than a
/// standalone `UserDefaults`-backed preference (as `hosts-switchr`'s equivalent does), since
/// `checkForUpdatesAutomatically` here is part of `AppSettings` — the one JSON-backed settings file
/// `GeneralSettingsView`'s toggle already writes through `AppModel.update(_:)`.
@MainActor
final class UpdateScheduler {
    static let launchDelay: TimeInterval = 600

    private let controller: UpdateController
    private weak var model: AppModel?
    private var timer: Timer?

    init(controller: UpdateController, model: AppModel) {
        self.controller = controller
        self.model = model
    }

    func start() {
        timer?.invalidate()
        timer = nil
        guard model?.settings.checkForUpdatesAutomatically == true else { return }
        let newTimer = Timer(timeInterval: Self.launchDelay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                // Re-read the setting: it may have been disabled during the wait.
                guard self?.model?.settings.checkForUpdatesAutomatically == true else { return }
                await self?.controller.checkNow(userInitiated: false)
            }
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    func stop() { timer?.invalidate(); timer = nil }
}
