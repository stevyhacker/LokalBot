import SwiftUI

enum LiveWaveformMath {
    static func height(index: Int, time: TimeInterval,
                       minHeight: CGFloat = 3, maxHeight: CGFloat = 18) -> CGFloat {
        let phase = time * 5.2
        let wave = (sin(phase + Double(index) * 0.72) + 1) / 2
        return max(minHeight,
                   min(maxHeight, minHeight + CGFloat(pow(wave, 0.7)) * (maxHeight - minHeight)))
    }
}

struct LiveWaveform: View {
    var barCount: Int = 9
    var barWidth: CGFloat = 4
    var maxHeight: CGFloat = 18
    var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if animated && !reduceMotion {
            SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { timeline in
                bars(at: timeline.date.timeIntervalSinceReferenceDate)
            }
        } else {
            bars(at: 0)
        }
    }

    private func bars(at time: TimeInterval) -> some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(.tint)
                    .frame(width: barWidth,
                           height: LiveWaveformMath.height(
                               index: index,
                               time: time,
                               maxHeight: maxHeight))
            }
        }
        .frame(height: maxHeight)
    }
}
