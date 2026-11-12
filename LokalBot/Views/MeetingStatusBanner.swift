import SwiftUI

/// One line of status at the top of a meeting's content: what happened and,
/// when there is one, the single thing to do about it.
struct MeetingStatusBanner<Message: View, Trailing: View>: View {
    enum Tone {
        /// Something to notice or fix.
        case attention
        /// Work in progress or an offer.
        case info
    }

    let tone: Tone
    var symbol: String?
    var busy = false
    @ViewBuilder var message: Message
    @ViewBuilder var trailing: Trailing

    /// A narrow column puts the action under the words instead of squeezing them.
    @State private var stacked = false

    var body: some View {
        Group {
            if stacked, Trailing.self != EmptyView.self {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        indicator
                        words
                    }
                    HStack(spacing: 10) { trailing }
                }
            } else {
                HStack(alignment: .center, spacing: 10) {
                    indicator
                    words
                    trailing
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lbStatusSurface(tone == .attention ? LBTokens.Palette.attention : Brand.teal)
        .onGeometryChange(for: Bool.self) { $0.size.width < 520 } action: { stacked = $0 }
    }

    @ViewBuilder private var indicator: some View {
        if busy {
            ProgressView().controlSize(.small)
        } else if let symbol {
            Image(systemName: symbol)
                .foregroundStyle(tone == .attention ? LBTokens.Palette.attentionText : LBTokens.Palette.accentText)
                .accessibilityHidden(true)
        }
    }

    private var words: some View {
        message
            .font(AppFont.scaled(.body))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension MeetingStatusBanner where Trailing == EmptyView {
    init(tone: Tone, symbol: String? = nil, busy: Bool = false, @ViewBuilder message: () -> Message) {
        self.init(tone: tone, symbol: symbol, busy: busy, message: message) { EmptyView() }
    }
}
