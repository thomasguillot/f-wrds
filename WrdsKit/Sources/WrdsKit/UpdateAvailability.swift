import Foundation

/// Pure policy that decides whether a fetched release is an installable update.
/// Fail-closed: an unparseable tag, a missing `.dmg`, or an asset URL that is not https and on
/// GitHub all mean `.upToDate` — a release this app cannot safely fetch is not an available update,
/// and saying so here rather than at download time keeps the offer honest.
public enum UpdateAvailability {
    public enum Outcome: Equatable, Sendable {
        case upToDate
        case available(version: AppVersion, dmgURL: URL, size: Int)
    }

    public static func evaluate(current: AppVersion, release: GitHubRelease) -> Outcome {
        guard let version = AppVersion(release.tagName), version > current else { return .upToDate }
        guard let dmg = release.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }) else {
            return .upToDate
        }
        guard let url = URL(string: dmg.browserDownloadURL),
              url.scheme?.lowercased() == "https",
              UpdateIntegrity.isAllowedHost(url) else {
            return .upToDate
        }
        return .available(version: version, dmgURL: url, size: dmg.size)
    }
}
