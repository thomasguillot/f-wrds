import Foundation
import Synchronization
import WrdsKit

/// A keystroke source the test drives by hand, in place of the event tap.
final class FakeKeystrokeSource: KeystrokeSource, @unchecked Sendable {
    var onKeyInput: ((KeyInput, _ fromAnotherApp: Bool) -> Void)?
    var onBufferInvalidatingEvent: (() -> Void)?
    var onTapDisabled: (() -> Void)?

    let startResult: Bool
    private let counts = Mutex((starts: 0, stops: 0))

    init(startResult: Bool = true) {
        self.startResult = startResult
    }

    var startCount: Int { counts.withLock { $0.starts } }
    var stopCount: Int { counts.withLock { $0.stops } }

    func start() -> Bool {
        counts.withLock { $0.starts += 1 }
        return startResult
    }

    func stop() {
        counts.withLock { $0.stops += 1 }
    }
}

/// An injector that records what it was asked to do instead of posting events.
final class FakeInjector: TextInjecting {
    enum Call: Equatable {
        case delete(Int)
        case paste(String)
        case type(String)
        case arrowLeft(Int)
    }

    private let recorded = Mutex<[Call]>([])

    var calls: [Call] { recorded.withLock { $0 } }

    func deleteCharacters(_ count: Int) { recorded.withLock { $0.append(.delete(count)) } }
    func paste(_ text: String, restoreClipboardAfter delay: TimeInterval) {
        recorded.withLock { $0.append(.paste(text)) }
    }
    func typeText(_ text: String) { recorded.withLock { $0.append(.type(text)) } }
    func pressArrowLeft(times: Int) { recorded.withLock { $0.append(.arrowLeft(times)) } }
    func clipboardText() -> String? { nil }
}

/// What `onNeedsForm` handed out, kept so a test can answer or cancel it.
struct FormRequest: Sendable {
    let snippet: Snippet
    let variable: Variable
    let match: TriggerMatch
    let originBundleID: String?
    let flow: UUID
}

/// An engine wired to fakes, started, and loaded with one group of snippets.
///
/// Every input helper waits for the engine's queue to drain before returning, so a test can assert
/// on `injector.calls` straight afterwards.
final class EngineHarness: Sendable {
    static let editor = "com.example.editor"

    let engine: ExpansionEngine
    let source = FakeKeystrokeSource()
    let injector = FakeInjector()
    let formRequests: AsyncStream<FormRequest>

    init(snippets: [Snippet], settings: AppSettings = .default, frontmost: String? = editor,
         start: Bool = true) {
        engine = ExpansionEngine(monitor: source, injector: injector)
        let (stream, continuation) = AsyncStream.makeStream(of: FormRequest.self)
        formRequests = stream
        engine.onNeedsForm = { snippet, variable, _, match, origin, flow in
            continuation.yield(FormRequest(snippet: snippet, variable: variable, match: match,
                                           originBundleID: origin, flow: flow))
        }
        engine.updateSettings(settings)
        engine.updateLibrary(groups: [SnippetGroup(name: "Test", snippets: snippets)], globals: [])
        engine.rebuildActiveSnippets(frontmostBundleID: frontmost)
        if start { _ = engine.start() }
        engine.waitUntilIdle()
    }

    func type(_ text: String, fromAnotherApp: Bool = false) {
        for character in text {
            source.onKeyInput?(.character(character), fromAnotherApp)
        }
        engine.waitUntilIdle()
    }

    func backspace(fromAnotherApp: Bool = false) {
        source.onKeyInput?(.backspace, fromAnotherApp)
        engine.waitUntilIdle()
    }

    func reset() {
        source.onKeyInput?(.reset, false)
        engine.waitUntilIdle()
    }

    func click() {
        source.onBufferInvalidatingEvent?()
        engine.waitUntilIdle()
    }

    func setPaused(_ paused: Bool) {
        engine.isPaused = paused
        engine.waitUntilIdle()
    }

    func setPanelSuspended(_ suspended: Bool) {
        engine.isPanelSuspended = suspended
        engine.waitUntilIdle()
    }

    func switchApp(to bundleID: String?) {
        engine.rebuildActiveSnippets(frontmostBundleID: bundleID)
        engine.waitUntilIdle()
    }

    func updateSettings(_ settings: AppSettings) {
        engine.updateSettings(settings)
        engine.waitUntilIdle()
    }

    func expand(_ snippet: Snippet, inApp bundleID: String? = nil) {
        engine.expand(snippet, inApp: bundleID)
        engine.waitUntilIdle()
    }

    func complete(_ request: FormRequest, answers: [String: String], flow: UUID? = nil) {
        engine.completeForm(answers: answers, snippet: request.snippet, match: request.match,
                            flow: flow ?? request.flow)
        engine.waitUntilIdle()
    }

    func cancel(flow: UUID) {
        engine.cancelForm(flow: flow)
        engine.waitUntilIdle()
    }
}

extension AppSettings {
    static func with(_ change: (inout AppSettings) -> Void) -> AppSettings {
        var settings = AppSettings.default
        change(&settings)
        return settings
    }
}
