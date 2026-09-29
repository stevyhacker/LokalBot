import SwiftUI

/// A compact audio overview with pointer scrubbing and a native accessibility
/// slider. The drag previews locally; releasing seeks once, preserving playback.
struct WaveformView: View {
    let sources: [WaveformAnalysis.Source]
    let currentTime: TimeInterval
    let duration: TimeInterval
    let onSeek: (TimeInterval) -> Void

    @State private var peaks: [Float]?
    @State private var loadedRequest: WaveformAnalysis.Request?
    @State private var isLoading = true
    @State private var hoverProgress: Double?
    @State private var scrubProgress: Double?
    @FocusState private var isFocused: Bool

    private var request: WaveformAnalysis.Request {
        .init(sources: sources, duration: duration)
    }
    private var progress: Double {
        WaveformAnalysis.clamp(duration > 0 ? currentTime / duration : 0)
    }
    private var displayedProgress: Double { scrubProgress ?? progress }
    private var previewProgress: Double? { scrubProgress ?? hoverProgress }
    private var availablePeaks: [Float]? { loadedRequest == request ? peaks : nil }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                waveform(in: geo.size)
                if let previewProgress {
                    Text(Transcript.stamp(previewProgress * duration))
                        .font(.scaledSystem(size: 10, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 3))
                        .fixedSize()
                        .position(x: min(max(28, previewProgress * geo.size.width),
                                         max(28, geo.size.width - 28)), y: 5)
                        .allowsHitTesting(false)
                } else if isLoading && availablePeaks == nil {
                    ProgressView().controlSize(.mini)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    isFocused = true
                    scrubProgress = position(value.location.x, width: geo.size.width)
                }
                .onEnded { value in
                    seek(position(value.location.x, width: geo.size.width))
                    scrubProgress = nil
                })
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoverProgress = position(location.x, width: geo.size.width)
                case .ended:
                    hoverProgress = nil
                }
            }
        }
        .frame(minWidth: 80)
        .frame(height: 40)
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(isFocused ? Color.accentColor : .clear, lineWidth: 2)
                .padding(-3)
                .allowsHitTesting(false)
        }
        .onKeyPress(.leftArrow) { adjust(by: -5); return .handled }
        .onKeyPress(.rightArrow) { adjust(by: 5); return .handled }
        .onKeyPress(.home) { seek(0); return .handled }
        .onKeyPress(.end) { seek(1); return .handled }
        .accessibilityRepresentation {
            Slider(value: Binding(get: { currentTime }, set: { onSeek($0) }),
                   in: 0...max(1, duration)) {
                Text("Playback position")
            }
            .accessibilityValue("\(Transcript.stamp(currentTime)) of \(Transcript.stamp(duration))")
            .accessibilityHint("Adjust to seek through the recording")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: adjust(by: 5)
                case .decrement: adjust(by: -5)
                @unknown default: break
                }
            }
            .accessibilityIdentifier("meeting.playbackPosition")
        }
        .help("Click or drag to seek. Left and Right arrows move 5 seconds.")
        .task(id: request) { await load(request) }
    }

    private func waveform(in size: CGSize) -> some View {
        let bars = WaveformAnalysis.resample(availablePeaks ?? [], width: size.width)
        return Canvas { context, _ in
            let center = size.height / 2
            let cut = size.width * displayedProgress
            var shape = Path()
            if bars.isEmpty {
                shape.addRoundedRect(in: CGRect(x: 0, y: center - 1, width: size.width, height: 2),
                                     cornerSize: CGSize(width: 1, height: 1))
            } else {
                let step = size.width / CGFloat(bars.count)
                let barWidth = max(1, step - 2)
                for (index, peak) in bars.enumerated() {
                    let height = max(2, CGFloat(peak) * (size.height - 10))
                    shape.addRoundedRect(
                        in: CGRect(x: CGFloat(index) * step, y: center - height / 2,
                                   width: barWidth, height: height),
                        cornerSize: CGSize(width: barWidth / 2, height: barWidth / 2))
                }
            }
            context.fill(shape, with: .color(.secondary.opacity(0.45)))
            var played = context
            played.clip(to: Path(CGRect(x: 0, y: 0, width: cut, height: size.height)))
            played.fill(shape, with: .color(Brand.teal))
            // A playhead makes position readable without relying on color alone.
            let playheadX = min(max(0, cut - 1), max(0, size.width - 2))
            context.fill(Path(roundedRect: CGRect(x: playheadX, y: 3, width: 2, height: size.height - 6),
                              cornerRadius: 1), with: .color(.primary))
            if let hoverProgress, scrubProgress == nil {
                let x = min(max(0, size.width * hoverProgress), max(0, size.width - 1))
                context.fill(Path(CGRect(x: x, y: 10, width: 1, height: size.height - 15)),
                             with: .color(.secondary))
            }
        }
        .clipped()
        .allowsHitTesting(false)
    }

    private func position(_ x: CGFloat, width: CGFloat) -> Double {
        WaveformAnalysis.clamp(x / max(width, 1))
    }

    private func seek(_ progress: Double) {
        onSeek(WaveformAnalysis.clamp(progress) * max(0, duration))
    }

    private func adjust(by seconds: TimeInterval) {
        scrubProgress = nil
        onSeek(min(max(0, currentTime + seconds), max(0, duration)))
    }

    private func load(_ request: WaveformAnalysis.Request) async {
        peaks = nil
        loadedRequest = nil
        isLoading = true
        scrubProgress = nil
        hoverProgress = nil
        let result = await WaveformAnalysis.load(request)
        guard !Task.isCancelled else { return }
        peaks = result
        loadedRequest = request
        isLoading = false
    }
}
