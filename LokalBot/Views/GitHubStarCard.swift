import SwiftUI

/// Today's one-time request for a GitHub star, at the end of the page. It
/// appears only when `GitHubStarPrompt.shouldShow` allows, and either button
/// retires it for good.
struct GitHubStarCard: View {
    @ObservedObject var store: GitHubStarPromptStore

    var body: some View {
        if store.showsPrompt {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    message
                    Spacer(minLength: 12)
                    actions.fixedSize()
                }
                VStack(alignment: .leading, spacing: 10) {
                    message
                    actions
                }
            }
            .font(.scaled(.body))
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lbGroupedSurface()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("today.githubStar")
        }
    }

    private var message: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "star").foregroundStyle(Brand.teal).accessibilityHidden(true)
            Text("LokalBot is free and built by one person. A GitHub star helps others find it.")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button("Star on GitHub") { store.openRepository() }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("today.githubStar.open")
            Button("Not now") { store.dismiss() }
                .buttonStyle(.workspaceLink)
                .accessibilityIdentifier("today.githubStar.dismiss")
        }
    }
}
