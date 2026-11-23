import Foundation
import WrdsKit

/// The form panel hand-off. Split out of `AppModel.swift` for the same reason as
/// `AppModel+Library.swift`/`AppModel+Picker.swift` — that class body was over SwiftLint's line
/// ceiling with this inlined — and reaching `formPanel`/`engine`/`formFailure`/`formFailureToken`
/// from here is why those lost their `private`/`private(set)` back in `AppModel.swift`; see the note
/// at each.
extension AppModel {
    /// How long a `formFailure` message stays in the menu before clearing itself.
    private static let formFailureDisplayDuration: TimeInterval = 6

    /// Answers a snippet that needs a form filled in. Called by the engine, on the main actor.
    ///
    /// Shows `formPanel` for `request` and wires its three outcomes straight onto the engine calls
    /// they exist to make: a completed answer becomes
    /// `engine.completeForm(answers:snippet:match:flow:)`, a cancelled one becomes
    /// `engine.cancelForm(flow:)`. `formPanel` itself decides which is which — Escape, a click
    /// outside, a snippet with more fields still to ask about, or the origin app not reactivating in
    /// time — this only has to hand it the two calls and a place to put a failure message.
    ///
    /// Both calls quote `request.flow` back, which is what makes a late answer or a late cancel from
    /// a flow that is already over land on nothing rather than on whatever has started since.
    func formNeeded(_ request: FormPanelController.FormRequest) {
        let engine = self.engine
        formPanel.show(
            request,
            onComplete: { answers in
                engine.completeForm(answers: answers, snippet: request.snippet,
                                    match: request.match, flow: request.flow)
            },
            onCancel: { engine.cancelForm(flow: request.flow) },
            onFailure: { [weak self] message in self?.showFormFailure(message) }
        )
    }

    /// Sets `formFailure` and schedules it to clear itself — see the property's own doc comment for
    /// why this one is transient where `hotKeyFailure` is not.
    private func showFormFailure(_ message: String) {
        formFailure = message
        let token = UUID()
        formFailureToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.formFailureDisplayDuration) { [weak self] in
            // `MainActor.assumeIsolated`, not a bare capture: the compiler cannot see that a GCD
            // `.main` queue closure runs on the main actor's own executor, only that it happens to in
            // practice — the same reasoning `AppModel.observeAppSwitches()` documents for its own
            // `queue: .main` notification handler.
            MainActor.assumeIsolated {
                // A newer failure already replaced this one — its own timer owns clearing it now.
                guard let self, self.formFailureToken == token else { return }
                self.formFailure = nil
            }
        }
    }
}
