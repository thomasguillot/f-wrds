import AppKit
import Foundation
import Observation
import WrdsKit

enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case available
    case downloading(received: Int, total: Int)
    case readyToInstall
    case failed(String)
}

@MainActor
@Observable
final class UpdateController {
    private(set) var state: UpdateState = .idle
    private(set) var plan: UpdatePlan?

    private let currentVersion: AppVersion?
    private let fetcher: ReleaseFetcher
    private let downloader: UpdateDownloader
    private let installer: UpdateInstaller
    private var downloadTask: Task<Void, Never>?
    private var downloadedDMG: URL?

    init(
        fetcher: ReleaseFetcher = ReleaseFetcher(),
        downloader: UpdateDownloader = UpdateDownloader(),
        installer: UpdateInstaller = UpdateInstaller(),
        bundleVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    ) {
        self.fetcher = fetcher
        self.downloader = downloader
        self.installer = installer
        self.currentVersion = bundleVersion.flatMap(AppVersion.init)
    }

    var currentDisplayVersion: String {
        currentVersion.map(displayVersion) ?? String(localized: "unknown")
    }

    func displayVersion(_ version: AppVersion) -> String {
        "\(version.major).\(version.minor).\(version.patch)"
    }

    // MARK: Check

    func checkNow(userInitiated: Bool) async {
        // Fail safe: an unparseable own version can't be compared, so never report a spurious update.
        guard let current = currentVersion else {
            state = .upToDate
            if userInitiated { showUpToDate() }
            return
        }

        state = .checking
        let releases: [GitHubRelease]
        do {
            releases = try await fetcher.fetchReleases()
        } catch {
            state = .failed(error.localizedDescription)
            if userInitiated { showFailure(error.localizedDescription) }
            return
        }

        guard let plan = UpdateAvailability.plan(current: current, releases: releases) else {
            self.plan = nil
            state = .upToDate
            if userInitiated { showUpToDate() }
            return
        }

        self.plan = plan
        state = .available
        guard UpdatePromptGate.shouldPrompt(
            latest: plan.version,
            skipped: UserDefaults.standard.skippedUpdateVersion.flatMap(AppVersion.init),
            interactive: userInitiated) else { return }
        UpdateWindowController.shared.show(controller: self)
    }

    /// Menu action: reopen the window if a plan is already in hand, else check.
    func showWindowOrCheck() async {
        if plan != nil {
            UpdateWindowController.shared.show(controller: self)
            return
        }
        await checkNow(userInitiated: true)
    }

    // MARK: Window actions

    func startDownload() {
        guard let plan else { return }
        downloadTask?.cancel()
        state = .downloading(received: 0, total: plan.size)
        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let dmg = try await downloader.downloadToTemp(
                    dmgURL: plan.dmgURL, expectedSize: plan.size, expectedChecksum: plan.checksum,
                    onProgress: { received, total in
                        Task { @MainActor [weak self] in
                            guard let self, case .downloading = state else { return }
                            state = .downloading(received: received, total: total)
                        }
                    })
                downloadedDMG = dmg
                state = .readyToInstall
            } catch is CancellationError {
                state = .available
            } catch let error as URLError where error.code == .cancelled {
                state = .available
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        state = .available
    }

    func installAndRelaunch() {
        guard let dmg = downloadedDMG else { return }
        do {
            let installedPath = try installer.install(dmgAt: dmg)
            downloadedDMG = nil
            // relaunch() terminates this instance; the spawned script reopens the new copy, whose
            // next launch is exactly what re-runs Task 17's grant check — see UpdateInstaller.relaunch.
            installer.relaunch(path: installedPath)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func skipThisVersion() {
        if let plan { UserDefaults.standard.skippedUpdateVersion = displayVersion(plan.version) }
        dismissWindow()
    }

    func dismissWindow() { UpdateWindowController.shared.close() }

    /// Closing the window abandons an in-flight download; the plan is kept so the
    /// menu item can reopen without re-checking.
    func windowClosed() {
        downloadTask?.cancel()
        downloadTask = nil
        if case .downloading = state { state = .available }
        if case .failed = state { state = .available }
    }

    // MARK: Alerts (interactive checks only)

    private func activate() { NSApplication.shared.activate(ignoringOtherApps: true) }

    private func showUpToDate() {
        activate()
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "You're up to date")
        alert.informativeText = String(localized: "F Wrds \(currentDisplayVersion) is the latest version.")
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }

    private func showFailure(_ message: String) {
        activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Update check failed")
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }
}

extension UserDefaults {
    private static let skippedUpdateVersionKey = "skippedUpdateVersion"

    /// The version "Skip This Version" last recorded, or `nil` if nothing has been skipped. Silences
    /// background update prompts up to this version only; a newer release prompts again and a manual
    /// check always does — see `UpdatePromptGate`.
    ///
    /// Device-local state, the same shape as `hasCompletedOnboarding` (`OnboardingView.swift`): not
    /// part of `AppSettings`, since a restored backup skipping a release for no reason of its own
    /// would be a bug, not a feature.
    var skippedUpdateVersion: String? {
        get { string(forKey: Self.skippedUpdateVersionKey) }
        set { set(newValue, forKey: Self.skippedUpdateVersionKey) }
    }
}
