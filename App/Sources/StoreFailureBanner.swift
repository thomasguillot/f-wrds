import SwiftUI

/// The one way a store failure is put in front of the user: every window that can cause one, or that
/// the user might go looking in, shows this.
///
/// A banner rather than an alert — the manager window is suppressed at launch, so an alert raised
/// during the first load would have nothing to attach to, and dismissing one would lose the only
/// copy of the message. This stays until it is read and dismissed.
struct StoreFailureBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let failure = model.storeFailure {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(failure)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Dismiss") { model.storeFailure = nil }
                    .buttonStyle(.link)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary)
        }
    }
}
