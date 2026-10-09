import SwiftUI

// MARK: - Hero panel

/// Adaptive welcome surface shared with the grouped content throughout the app.
struct HeroPanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(14)
            .lbGroupedSurface()
    }
}
