import SwiftUI

struct HeroPanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(14)
            .lbGroupedSurface()
    }
}
