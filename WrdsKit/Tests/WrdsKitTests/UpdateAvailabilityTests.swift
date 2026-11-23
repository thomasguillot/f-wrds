import Foundation
import Testing
@testable import WrdsKit

@Suite struct UpdateAvailabilityTests {
    private func release(tag: String, assets: [GitHubRelease.Asset]) -> GitHubRelease {
        GitHubRelease(tagName: tag, htmlURL: "https://github.com/owner/repo/releases/latest", assets: assets)
    }

    private func dmg(name: String = "FWrds.dmg", url: String, size: Int = 4096) -> GitHubRelease.Asset {
        GitHubRelease.Asset(name: name, browserDownloadURL: url, contentType: "application/x-apple-diskimage", size: size)
    }

    private let current = AppVersion("0.1.2")!

    @Test func newerTagWithHTTPSDMGIsAvailable() {
        let url = "https://github.com/owner/repo/releases/download/v0.2.0/FWrds.dmg"
        let outcome = UpdateAvailability.evaluate(
            current: current,
            release: release(tag: "0.2.0", assets: [dmg(url: url, size: 5000)]))
        #expect(outcome == .available(version: AppVersion("0.2.0")!, dmgURL: URL(string: url)!, size: 5000))
    }

    @Test func leadingVTagHandled() {
        let url = "https://github.com/owner/repo/releases/download/v0.2.0/FWrds.dmg"
        let outcome = UpdateAvailability.evaluate(
            current: current,
            release: release(tag: "v0.2.0", assets: [dmg(url: url)]))
        #expect(outcome == .available(version: AppVersion("0.2.0")!, dmgURL: URL(string: url)!, size: 4096))
    }

    @Test func olderTagIsUpToDate() {
        let url = "https://github.com/owner/repo/releases/download/v0.1.0/FWrds.dmg"
        let outcome = UpdateAvailability.evaluate(
            current: current,
            release: release(tag: "0.1.0", assets: [dmg(url: url)]))
        #expect(outcome == .upToDate)
    }

    @Test func equalTagIsUpToDate() {
        let url = "https://github.com/owner/repo/releases/download/v0.1.2/FWrds.dmg"
        let outcome = UpdateAvailability.evaluate(
            current: current,
            release: release(tag: "0.1.2", assets: [dmg(url: url)]))
        #expect(outcome == .upToDate)
    }

    @Test func missingDMGIsUpToDate() {
        let zip = GitHubRelease.Asset(
            name: "source.zip",
            browserDownloadURL: "https://github.com/owner/repo/releases/download/v0.2.0/source.zip",
            contentType: "application/zip", size: 1024)
        let outcome = UpdateAvailability.evaluate(
            current: current,
            release: release(tag: "0.2.0", assets: [zip]))
        #expect(outcome == .upToDate)
    }

    @Test func nonHTTPSDMGIsUpToDate() {
        let url = "http://github.com/owner/repo/releases/download/v0.2.0/FWrds.dmg"
        let outcome = UpdateAvailability.evaluate(
            current: current,
            release: release(tag: "0.2.0", assets: [dmg(url: url)]))
        #expect(outcome == .upToDate)
    }

    @Test func picksDMGAmongMultipleAssets() {
        let zip = GitHubRelease.Asset(
            name: "source.zip",
            browserDownloadURL: "https://github.com/owner/repo/releases/download/v0.2.0/source.zip",
            contentType: "application/zip", size: 1024)
        let dmgURL = "https://github.com/owner/repo/releases/download/v0.2.0/FWrds-0.2.0.dmg"
        let dmgAsset = dmg(name: "FWrds-0.2.0.DMG", url: dmgURL, size: 7777)
        let outcome = UpdateAvailability.evaluate(
            current: current,
            release: release(tag: "0.2.0", assets: [zip, dmgAsset]))
        #expect(outcome == .available(version: AppVersion("0.2.0")!, dmgURL: URL(string: dmgURL)!, size: 7777))
    }

    @Test func assetHostedOffGitHubIsUpToDate() {
        // A release this app would refuse to download is not an available update. Refusing here
        // rather than at download time keeps the offer honest: nothing is announced that cannot
        // then be installed.
        let url = "https://cdn.example.com/releases/v0.2.0/FWrds.dmg"
        let outcome = UpdateAvailability.evaluate(
            current: current,
            release: release(tag: "0.2.0", assets: [dmg(url: url)]))
        #expect(outcome == .upToDate)
    }

    @Test func unparseableTagIsUpToDate() {
        let url = "https://github.com/owner/repo/releases/download/nightly/FWrds.dmg"
        let outcome = UpdateAvailability.evaluate(
            current: current,
            release: release(tag: "nightly", assets: [dmg(url: url)]))
        #expect(outcome == .upToDate)
    }
}
