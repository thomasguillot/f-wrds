import Foundation
import WrdsKit

/// Allows a redirect only when its target stays https and stays on GitHub.
///
/// The API endpoint below is a constant this app wrote itself, so the first request cannot go
/// anywhere unexpected — but a response can redirect, and by default `URLSession` follows wherever
/// it is pointed. This is the second half of the same fail-closed rule
/// `UpdateDownloader.DownloadRedirectGuard` applies to the asset download.
private final class FetchRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
    ) async -> URLRequest? {
        guard request.url?.scheme?.lowercased() == "https",
              UpdateIntegrity.isAllowedHost(request.url)
        else { return nil }
        return request
    }
}

struct ReleaseFetcher: Sendable {
    enum FetchError: LocalizedError {
        case insecureURL, badStatus(Int), tooLarge

        var errorDescription: String? {
            switch self {
            case .insecureURL:
                // Reachable only if the endpoint below were edited into something else, which makes
                // it a sentence about this app rather than about the network.
                return String(localized: "F Wrds couldn't find where to check for updates.")
            case .badStatus:
                return String(localized: "F Wrds couldn't get the latest version number from GitHub.")
            case .tooLarge:
                return String(localized: "GitHub sent something unexpected. Try again later.")
            }
        }
    }

    private static let repoSlug = "thomasguillot/f-wrds"
    // A page of history, not just /latest: the update window shows the notes for
    // every release the user skipped, so it needs more than the newest one.
    private static let pageSize = 30
    private static let maxBytes = 2 * 1024 * 1024

    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func fetchReleases() async throws -> [GitHubRelease] {
        let endpoint = "https://api.github.com/repos/\(Self.repoSlug)/releases?per_page=\(Self.pageSize)"
        guard let url = URL(string: endpoint), url.scheme?.lowercased() == "https",
              UpdateIntegrity.isAllowedHost(url)
        else {
            throw FetchError.insecureURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request, delegate: FetchRedirectGuard())

        guard let http = response as? HTTPURLResponse else { throw FetchError.badStatus(-1) }
        guard http.statusCode == 200 else { throw FetchError.badStatus(http.statusCode) }
        guard data.count <= Self.maxBytes else { throw FetchError.tooLarge }

        return try JSONDecoder().decode([GitHubRelease].self, from: data)
    }
}
