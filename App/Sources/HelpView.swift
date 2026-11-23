import SwiftUI

/// The topics in the Help window, in the order the sidebar lists them. Their titles and text live in
/// `HelpTopics.swift`.
enum HelpTopic: String, CaseIterable, Identifiable {
    case gettingStarted, snippets, variables, groups, picker, injection, espanso, troubleshooting

    var id: String { rawValue }
}

/// One piece of a topic's text.
enum HelpBlock {
    case heading(LocalizedStringKey)
    case paragraph(LocalizedStringKey)
    case bullets([LocalizedStringKey])
}

/// The Help window: a topic list on the left and the selected topic's text on the right.
struct HelpView: View {
    @State private var selection: HelpTopic? = .gettingStarted

    var body: some View {
        NavigationSplitView {
            List(HelpTopic.allCases, selection: $selection) { topic in
                Label(topic.title, systemImage: topic.symbol)
                    .tag(topic)
            }
            .navigationSplitViewColumnWidth(min: 250, ideal: 260, max: 320)
        } detail: {
            if let selection {
                HelpTopicView(topic: selection)
            }
        }
        .navigationTitle("F Wrds Help")
    }
}

private struct HelpTopicView: View {
    let topic: HelpTopic

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(topic.title)
                    .font(.largeTitle.bold())
                    .padding(.bottom, 4)
                ForEach(Array(topic.blocks.enumerated()), id: \.offset) { _, block in
                    view(for: block)
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .id(topic)
    }

    @ViewBuilder
    private func view(for block: HelpBlock) -> some View {
        switch block {
        case .heading(let text):
            Text(text)
                .font(.title3.bold())
                .padding(.top, 10)
        case .paragraph(let text):
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\u{2022}")
                            .foregroundStyle(.secondary)
                        Text(item)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
