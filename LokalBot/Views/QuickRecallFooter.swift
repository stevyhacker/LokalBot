import SwiftUI

struct QuickRecallFooter: View {
    let query: String
    let inference: InferencePresentation
    let hasResults: Bool
    let isSearching: Bool
    let ask: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            if hasResults {
                HStack(spacing: 12) {
                    Text("↑↓ Navigate")
                    Text("↩ Open")
                }
                .font(.scaled(.caption))
                .foregroundStyle(.secondary)
                .accessibilityLabel("Use the arrow keys to navigate and Return to open a result")
            }
            Spacer(minLength: 0)
            if !query.isEmpty {
                VStack(alignment: .trailing, spacing: 4) {
                    Button(action: ask) {
                        HStack(spacing: 7) {
                            Image(systemName: "sparkles")
                            Text("Ask about “\(query)”")
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("⌘↩")
                                .font(.scaled(.caption).monospaced())
                                .padding(.leading, 3)
                        }
                        .font(.scaled(.callout).weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(isSearching)
                    .accessibilityIdentifier("quickRecall.ask")
                    .help("Open Ask with this query and its matching sources")
                    Label(inference.label, systemImage: inference.icon)
                        .font(.scaled(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(inference.detail(
                            local: "Ask uses a model on this Mac.",
                            remote: "Ask uses your configured remote model."))
                }
                .frame(maxWidth: 350, alignment: .trailing)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(minHeight: 42)
    }
}
