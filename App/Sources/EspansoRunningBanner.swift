import SwiftUI

/// Says that Espanso is running alongside F Wrds, and offers to quit it.
struct EspansoRunningBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.isEspansoRunning {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("""
                    Espanso, another text expander, is still running. Both apps react to the same \
                    triggers, so your text comes out garbled. Quit Espanso to fix it.
                    """)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Quit Espanso") { model.quitEspanso() }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary)
        }
    }
}
