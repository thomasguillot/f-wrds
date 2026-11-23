import Foundation
import WrdsKit

/// Allows a redirect only when its target stays https *and* stays on GitHub; anything else is
/// cancelled and recorded so the caller can say which of the two it was.
///
/// The host half is not redundant with the scheme half. A release asset URL redirects — that is how
/// GitHub serves them — so this app follows hops it did not choose, and https only says the hop was
/// private, not that the other end is who was meant to answer. See `UpdateIntegrity`.
private final class DownloadRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _blocked: UpdateDownloader.DownloadError?
    var blockedRedirect: UpdateDownloader.DownloadError? { lock.withLock { _blocked } }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
    ) async -> URLRequest? {
        guard request.url?.scheme?.lowercased() == "https" else {
            lock.withLock { _blocked = .insecureRedirect }
            return nil
        }
        guard UpdateIntegrity.isAllowedHost(request.url) else {
            lock.withLock { _blocked = .disallowedRedirect }
            return nil
        }
        return request
    }
}

/// Writes body chunks directly to a FileHandle so no in-memory buffer accumulates. Status/size
/// validation happens before any body is drained.
private final class DownloadBodyDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    // Denylist, not allowlist: an interstitial/error page served instead of the DMG is the failure
    // mode we care about; unknown or absent MIME types are allowed through.
    static let rejectedMimeTypes: Set<String> = ["text/html", "text/plain"]

    private let redirectGuard: DownloadRedirectGuard
    private let fileHandle: FileHandle
    private let maxBytes: Int
    private let expectedSize: Int
    private let onProgress: @Sendable (Int, Int) -> Void
    // Lock-free by URLSession ordering: the response disposition returns before any body chunk,
    // and completion fires after the last chunk — so these are never touched concurrently.
    private var received = 0
    private var errorFlag: Error?

    private let lock = NSLock()
    private var _continuation: CheckedContinuation<Void, Error>?
    private var _completionResult: Result<Void, Error>?

    init(
        redirectGuard: DownloadRedirectGuard,
        fileHandle: FileHandle,
        maxBytes: Int,
        expectedSize: Int,
        onProgress: @escaping @Sendable (Int, Int) -> Void
    ) {
        self.redirectGuard = redirectGuard
        self.fileHandle = fileHandle
        self.maxBytes = maxBytes
        self.expectedSize = expectedSize
        self.onProgress = onProgress
    }

    func waitForCompletion() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                if let result = _completionResult {
                    switch result {
                    case .success: continuation.resume()
                    case .failure(let failure): continuation.resume(throwing: failure)
                    }
                } else {
                    _continuation = continuation
                }
            }
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
    ) async -> URLRequest? {
        await redirectGuard.urlSession(
            session, task: task, willPerformHTTPRedirection: response, newRequest: request)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask,
        didReceive response: URLResponse
    ) async -> URLSession.ResponseDisposition {
        guard let http = response as? HTTPURLResponse else {
            errorFlag = UpdateDownloader.DownloadError.badStatus(-1)
            return .cancel
        }
        guard http.statusCode == 200 else {
            errorFlag = UpdateDownloader.DownloadError.badStatus(http.statusCode)
            return .cancel
        }
        // expectedContentLength is -1 when unknown, so an undeclared length won't false-trigger.
        if http.expectedContentLength > Int64(maxBytes) {
            errorFlag = UpdateDownloader.DownloadError.tooLarge
            return .cancel
        }
        if expectedSize > 0, http.expectedContentLength >= 0,
            http.expectedContentLength != Int64(expectedSize) {
            errorFlag = UpdateDownloader.DownloadError.sizeMismatch
            return .cancel
        }
        if let mimeType = response.mimeType, Self.rejectedMimeTypes.contains(mimeType.lowercased()) {
            errorFlag = UpdateDownloader.DownloadError.unexpectedContentType
            return .cancel
        }
        return .allow
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        received += data.count
        if received > maxBytes {
            dataTask.cancel()
            errorFlag = UpdateDownloader.DownloadError.tooLarge
            return
        }
        do {
            try fileHandle.write(contentsOf: data)
        } catch {
            // didCompleteWithError owns the single fileHandle.close(); don't close it here.
            errorFlag = error
            dataTask.cancel()
            return
        }
        onProgress(received, expectedSize)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        var closeError: Error?
        do { try fileHandle.close() } catch { closeError = error }
        let taskResult: Result<Void, Error>
        if let error = errorFlag ?? error {
            taskResult = .failure(error)
        } else if let error = closeError {
            taskResult = .failure(error)
        } else if expectedSize > 0, received != expectedSize {
            taskResult = .failure(UpdateDownloader.DownloadError.sizeMismatch)
        } else {
            taskResult = .success(())
        }
        var cont: CheckedContinuation<Void, Error>?
        lock.withLock {
            cont = _continuation
            _continuation = nil
            if cont == nil { _completionResult = taskResult }
        }
        if let cont {
            switch taskResult {
            case .success: cont.resume()
            case .failure(let failure): cont.resume(throwing: failure)
            }
        }
    }
}

struct UpdateDownloader: Sendable {
    enum DownloadError: LocalizedError {
        case insecureURL, insecureRedirect, disallowedURL, disallowedRedirect
        case badStatus(Int), tooLarge, writeFailed
        case sizeMismatch, unexpectedContentType, checksumMismatch

        var errorDescription: String? {
            switch self {
            case .insecureURL, .insecureRedirect:
                return String(localized: "The update wasn't sent over a secure connection, so it wasn't installed.")
            case .disallowedURL, .disallowedRedirect:
                return String(localized: "The update didn't come from GitHub, so it wasn't installed.")
            case .badStatus:
                return String(localized: "The update couldn't be downloaded from GitHub.")
            case .tooLarge:
                return String(localized: "The update is much larger than expected, so it wasn't installed.")
            case .writeFailed:
                return String(localized: "The update couldn't be written to disk.")
            case .sizeMismatch:
                return String(localized: "The download was incomplete. Try again.")
            case .unexpectedContentType:
                return String(localized: "The download wasn't a disk image, so it wasn't installed.")
            case .checksumMismatch:
                return String(localized: """
                    The download doesn't match its published checksum, so it wasn't installed.
                    """)
            }
        }
    }

    private static let maxBytes = 500 * 1024 * 1024

    private let session: URLSession
    private nonisolated(unsafe) let fileManager: FileManager

    init(session: URLSession = .shared, fileManager: FileManager = .default) {
        self.session = session
        self.fileManager = fileManager
    }

    /// Streams the verified `.dmg` to a unique temp file and returns its path.
    /// The caller (UpdateInstaller) mounts and installs from it. Every https,
    /// host, size, and content-type guard runs before any byte is written; the
    /// checksum is checked once the last byte has.
    ///
    /// - Parameter expectedChecksum: the SHA-256 the release publishes for this image, or `nil`
    ///   when it publishes none. Present, it is binding: a download that does not hash to it is
    ///   deleted and reported rather than installed. Absent, the download proceeds — releases
    ///   published before this app started verifying have no such line, and refusing an update over
    ///   a missing sentence in a release note would strand users on an old version for nothing.
    func downloadToTemp(
        dmgURL: URL, expectedSize: Int, expectedChecksum: String? = nil,
        onProgress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> URL {
        // Fail closed: never download over a non-https URL.
        guard dmgURL.scheme?.lowercased() == "https" else { throw DownloadError.insecureURL }
        // …and never from anywhere but this app's one release channel. https says the connection is
        // private; this says who is on the other end of it.
        guard UpdateIntegrity.isAllowedHost(dmgURL) else { throw DownloadError.disallowedURL }
        // Reject the advertised size before issuing any network request.
        if expectedSize > Self.maxBytes { throw DownloadError.tooLarge }

        var request = URLRequest(url: dmgURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 120

        let tempURL = fileManager.temporaryDirectory
            .appendingPathComponent("fwrds-update-\(UUID().uuidString).dmg")
        let fileHandle = try makeWritableTempFile(at: tempURL)

        let redirectGuard = DownloadRedirectGuard()
        let delegate = DownloadBodyDelegate(
            redirectGuard: redirectGuard, fileHandle: fileHandle, maxBytes: Self.maxBytes,
            expectedSize: expectedSize, onProgress: onProgress)
        let task = session.dataTask(with: request)
        task.delegate = delegate
        task.resume()

        do {
            try await withTaskCancellationHandler {
                try await delegate.waitForCompletion()
            } onCancel: {
                task.cancel()
            }
        } catch {
            task.cancel()
            try? fileManager.removeItem(at: tempURL)
            if let blocked = redirectGuard.blockedRedirect { throw blocked }
            throw error
        }
        // Even if the delegate finished before cancellation propagated, refuse to install.
        if Task.isCancelled { try? fileManager.removeItem(at: tempURL); throw CancellationError() }
        if let blocked = redirectGuard.blockedRedirect {
            try? fileManager.removeItem(at: tempURL)
            throw blocked
        }
        // Last, because it is the only check that needs the whole file: everything above is about
        // where the bytes came from, and this is the one thing that says what they are.
        if let expectedChecksum, try !UpdateIntegrity.fileAt(tempURL, matchesSHA256: expectedChecksum) {
            try? fileManager.removeItem(at: tempURL)
            throw DownloadError.checksumMismatch
        }

        return tempURL
    }

    private func makeWritableTempFile(at url: URL) throws -> FileHandle {
        guard fileManager.createFile(atPath: url.path, contents: nil) else {
            throw DownloadError.writeFailed
        }
        do {
            return try FileHandle(forWritingTo: url)
        } catch {
            try? fileManager.removeItem(at: url)
            throw error
        }
    }
}
