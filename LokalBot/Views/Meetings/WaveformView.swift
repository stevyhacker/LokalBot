import AppKit
import SwiftUI

struct WaveformView: View {
    private static let selectionYellow = Color(red: 0.96, green: 0.76, blue: 0.14)

    let sources: [WaveformAnalysis.Source]
    let currentTime: TimeInterval
    let duration: TimeInterval
    var windowStart: TimeInterval = 0
    var windowEnd: TimeInterval?
    var height: CGFloat = 60
    @Binding var selection: Meeting.ContentRange?
    var isBusy = false
    var hasTrimmedBoundaries = false
    let onSeek: (TimeInterval) -> Void
    var onTrimSelection: ((Meeting.ContentRange) -> Void)?
    var onExtractSelection: ((Meeting.ContentRange) -> Void)?
    var onRestoreFullRecording: (() -> Void)?

    @State private var peaks: [Float]?
    @State private var loadedRequest: WaveformAnalysis.Request?
    @State private var isLoading = true
    @State private var hoverProgress: Double?
    @State private var scrubProgress: Double?
    @State private var pendingSelectionStart: TimeInterval?
    @State private var viewport = WaveformViewport()
    @State private var viewWidth: CGFloat = 0
    @State private var isHovering = false
    @State private var scrollMonitor: Any?
    @State private var dragStartedInScrollbar: Bool?
    @State private var previousScrollbarDragX: Double = 0
    @FocusState private var isFocused: Bool

    private var effectiveStart: TimeInterval { max(0, windowStart) }
    private var effectiveEnd: TimeInterval { max(effectiveStart, windowEnd ?? duration) }

    private var request: WaveformAnalysis.Request {
        .init(sources: sources, duration: duration, binCount: WaveformAnalysis.detailBinCount)
    }
    private var previewProgress: Double? { scrubProgress ?? hoverProgress }
    private var availablePeaks: [Float]? { loadedRequest == request ? peaks : nil }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                waveform(in: geo.size)
                if let previewProgress {
                    Text(Transcript.stamp(viewport.time(atFraction: previewProgress)))
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
                if viewport.zoom > 1.01 {
                    Button {
                        viewport.reset()
                    } label: {
                        Text(verbatim: "\(Int(viewport.zoom.rounded()))x")
                            .font(.scaledSystem(size: 10, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .help("Reset zoom")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(4)
                }
            }
            .contentShape(Rectangle())
            .onAppear {
                viewWidth = geo.size.width
                viewport.updateBounds(windowStart: effectiveStart, windowEnd: effectiveEnd)
            }
            .onChange(of: geo.size.width) { _, newWidth in
                viewWidth = newWidth
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragStartedInScrollbar == nil {
                        dragStartedInScrollbar = viewport.zoom > 1.01 && value.startLocation.y >= geo.size.height - 8
                    }
                    if dragStartedInScrollbar == true {
                        let deltaX = Double(value.translation.width) - previousScrollbarDragX
                        previousScrollbarDragX = Double(value.translation.width)
                        viewport.pan(by: (deltaX / max(geo.size.width, 1)) * viewport.totalSpan)
                    } else {
                        isFocused = true
                        scrubProgress = position(value.location.x, width: geo.size.width)
                    }
                }
                .onEnded { value in
                    let wasScrollbar = dragStartedInScrollbar == true
                    dragStartedInScrollbar = nil
                    previousScrollbarDragX = 0
                    if !wasScrollbar {
                        let fraction = position(value.location.x, width: geo.size.width)
                        let clickedTime = viewport.time(atFraction: fraction)
                        onSeek(clickedTime)
                        var state = WaveformSelectionState(pendingStart: pendingSelectionStart, selection: selection)
                        state.handleLeftClick(at: clickedTime, bounds: effectiveStart...effectiveEnd)
                        pendingSelectionStart = state.pendingStart
                        selection = state.selection
                        scrubProgress = nil
                    }
                })
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    isHovering = true
                    hoverProgress = position(location.x, width: geo.size.width)
                    installScrollMonitorIfNeeded()
                case .ended:
                    isHovering = false
                    hoverProgress = nil
                    removeScrollMonitor()
                }
            }
        }
        .frame(minWidth: 80)
        .frame(height: height)
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(isFocused ? Color.accentColor : .clear, lineWidth: 2)
                .padding(-3)
                .allowsHitTesting(false)
        }
        .contextMenu {
            Button("Trim to Selection") {
                if let selection { onTrimSelection?(selection) }
            }
            .disabled(selection == nil || isBusy)
            Button("New Meeting from Selection") {
                if let selection { onExtractSelection?(selection) }
            }
            .disabled(selection == nil || isBusy)
            if selection != nil || pendingSelectionStart != nil {
                Divider()
                Button("Clear Selection") {
                    pendingSelectionStart = nil
                    selection = nil
                }
            }
            if hasTrimmedBoundaries {
                Divider()
                Button("Use full recording") {
                    onRestoreFullRecording?()
                }
                .disabled(isBusy)
            }
        }
        .onKeyPress(.leftArrow) { adjust(by: -5); return .handled }
        .onKeyPress(.rightArrow) { adjust(by: 5); return .handled }
        .onKeyPress(.home) { seek(to: effectiveStart); return .handled }
        .onKeyPress(.end) { seek(to: effectiveEnd); return .handled }
        .onKeyPress(.escape) {
            guard pendingSelectionStart != nil || selection != nil else { return .ignored }
            pendingSelectionStart = nil
            selection = nil
            return .handled
        }
        .accessibilityRepresentation {
            Slider(value: Binding(get: { currentTime }, set: { onSeek($0) }),
                   in: effectiveStart...max(effectiveStart + 1, effectiveEnd)) {
                Text("Playback position")
            }
            .accessibilityValue("\(Transcript.stamp(currentTime)) of \(Transcript.stamp(effectiveEnd))")
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
        .help("Click to seek and mark selection start/end. Scroll wheel zooms, Esc clears selection.")
        .task(id: request) { await load(request) }
        .onChange(of: effectiveStart) { _, _ in
            pendingSelectionStart = nil
            viewport.updateBounds(windowStart: effectiveStart, windowEnd: effectiveEnd)
        }
        .onChange(of: effectiveEnd) { _, _ in
            pendingSelectionStart = nil
            viewport.updateBounds(windowStart: effectiveStart, windowEnd: effectiveEnd)
        }
        .onDisappear {
            isHovering = false
            removeScrollMonitor()
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    private func waveform(in size: CGSize) -> some View {
        let bars = WaveformAnalysis.resample(
            availablePeaks ?? [],
            duration: duration,
            visibleStart: viewport.visibleStart,
            visibleEnd: viewport.visibleEnd,
            width: size.width)
        let inset: CGFloat = size.height < 32 ? 4 : 10
        let bottomReserve: CGFloat = viewport.zoom > 1.01 ? 5 : 0
        let barAreaHeight = max(8, size.height - bottomReserve)
        return Canvas { context, _ in
            let center = barAreaHeight / 2
            let playheadFraction = scrubProgress ?? viewport.fraction(at: currentTime)
            let cut = size.width * WaveformAnalysis.clamp(playheadFraction)
            let selStartX = selection.map { viewport.fraction(at: $0.start) * size.width }
            let selEndX = selection.map { viewport.fraction(at: $0.end) * size.width }

            if let selStartX, let selEndX {
                let left = max(0, min(selStartX, selEndX))
                let right = min(size.width, max(selStartX, selEndX))
                if right > left {
                    context.fill(
                        Path(CGRect(x: left, y: 0, width: right - left, height: barAreaHeight)),
                        with: .color(Self.selectionYellow.opacity(0.18)))
                }
            } else if let pendingSelectionStart, let hoverProgress {
                let pendingX = viewport.fraction(at: pendingSelectionStart) * size.width
                let hoverX = hoverProgress * size.width
                let left = max(0, min(pendingX, hoverX))
                let right = min(size.width, max(pendingX, hoverX))
                if right > left {
                    context.fill(
                        Path(CGRect(x: left, y: 0, width: right - left, height: barAreaHeight)),
                        with: .color(Self.selectionYellow.opacity(0.10)))
                }
            }

            var shape = Path()
            if bars.isEmpty {
                shape.addRoundedRect(in: CGRect(x: 0, y: center - 1, width: size.width, height: 2),
                                     cornerSize: CGSize(width: 1, height: 1))
            } else {
                let step = size.width / CGFloat(bars.count)
                let barWidth = max(1, step - 2)
                for (index, peak) in bars.enumerated() {
                    let barHeight = max(2, CGFloat(peak) * (barAreaHeight - inset))
                    shape.addRoundedRect(
                        in: CGRect(x: CGFloat(index) * step, y: center - barHeight / 2,
                                   width: barWidth, height: barHeight),
                        cornerSize: CGSize(width: barWidth / 2, height: barWidth / 2))
                }
            }
            context.fill(shape, with: .color(.secondary.opacity(0.45)))

            if cut > 0 {
                var played = context
                played.clip(to: Path(CGRect(x: 0, y: 0, width: cut, height: barAreaHeight)))
                played.fill(shape, with: .color(Brand.teal))
            }

            if let selStartX, let selEndX {
                let left = max(0, min(selStartX, selEndX))
                let right = min(size.width, max(selStartX, selEndX))
                if right > left {
                    var selected = context
                    selected.clip(to: Path(CGRect(x: left, y: 0, width: right - left, height: barAreaHeight)))
                    selected.fill(shape, with: .color(Self.selectionYellow))
                }
                for boundaryX in [selStartX, selEndX] where boundaryX >= -2 && boundaryX <= size.width + 2 {
                    let clampedX = min(max(0, boundaryX - 1), max(0, size.width - 2))
                    context.fill(
                        Path(roundedRect: CGRect(x: clampedX, y: 0, width: 2, height: barAreaHeight), cornerRadius: 1),
                        with: .color(Self.selectionYellow))
                }
            } else if let pendingSelectionStart {
                let pendingX = viewport.fraction(at: pendingSelectionStart) * size.width
                if pendingX >= -2 && pendingX <= size.width + 2 {
                    let clampedX = min(max(0, pendingX - 1), max(0, size.width - 2))
                    context.fill(
                        Path(roundedRect: CGRect(x: clampedX, y: 0, width: 2, height: barAreaHeight), cornerRadius: 1),
                        with: .color(Self.selectionYellow))
                }
            }

            if scrubProgress != nil || (playheadFraction >= 0 && playheadFraction <= 1) {
                let playheadX = min(max(0, cut - 1), max(0, size.width - 2))
                context.fill(
                    Path(roundedRect: CGRect(x: playheadX, y: inset * 0.3, width: 2, height: barAreaHeight - inset * 0.6),
                         cornerRadius: 1),
                    with: .color(.primary))
            }
            if let hoverProgress, scrubProgress == nil {
                let x = min(max(0, size.width * hoverProgress), max(0, size.width - 1))
                context.fill(
                    Path(CGRect(x: x, y: inset, width: 1, height: barAreaHeight - inset * 1.5)),
                    with: .color(.secondary))
            }

            if viewport.zoom > 1.01 && viewport.totalSpan > 0 {
                let trackRect = CGRect(x: 0, y: size.height - 3, width: size.width, height: 3)
                context.fill(Path(roundedRect: trackRect, cornerRadius: 1.5), with: .color(.secondary.opacity(0.18)))
                let thumbX = ((viewport.visibleStart - viewport.windowStart) / viewport.totalSpan) * size.width
                let thumbWidth = max(18, (viewport.visibleSpan / viewport.totalSpan) * size.width)
                let clampedThumbX = min(max(0, thumbX), max(0, size.width - thumbWidth))
                let thumbRect = CGRect(x: clampedThumbX, y: size.height - 3, width: thumbWidth, height: 3)
                context.fill(Path(roundedRect: thumbRect, cornerRadius: 1.5), with: .color(.secondary.opacity(0.55)))
            }
        }
        .clipped()
        .allowsHitTesting(false)
    }

    private func installScrollMonitorIfNeeded() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { event in
            guard isHovering else { return event }
            return handleNavigationEvent(event)
        }
    }

    private func removeScrollMonitor() {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
    }

    private func handleNavigationEvent(_ event: NSEvent) -> NSEvent? {
        let anchor = hoverProgress ?? 0.5
        if event.type == .magnify {
            let factor = max(0.5, min(2.0, 1.0 + Double(event.magnification)))
            viewport.zoom(by: factor, anchorFraction: anchor)
            return nil
        }
        guard event.type == .scrollWheel else { return event }
        let dx = Double(event.scrollingDeltaX)
        let dy = Double(event.scrollingDeltaY)
        let isHorizontalPan = event.modifierFlags.contains(.shift) || abs(dx) > abs(dy)
        if isHorizontalPan {
            guard viewport.zoom > 1.001 else { return event }
            let rawDelta = abs(dx) > abs(dy) ? dx : dy
            let pixelDelta = event.hasPreciseScrollingDeltas ? rawDelta : rawDelta * 12
            let deltaSeconds = (-pixelDelta / max(Double(viewWidth), 1)) * viewport.visibleSpan
            viewport.pan(by: deltaSeconds)
            return nil
        }
        guard abs(dy) > 0.001 else { return nil }
        let step = event.hasPreciseScrollingDeltas ? dy * 0.01 : dy * 0.12
        let factor = exp(min(0.6, max(-0.6, step)))
        viewport.zoom(by: factor, anchorFraction: anchor)
        return nil
    }

    private func position(_ x: CGFloat, width: CGFloat) -> Double {
        WaveformAnalysis.clamp(x / max(width, 1))
    }

    private func seek(to time: TimeInterval) {
        onSeek(min(max(effectiveStart, time), effectiveEnd))
    }

    private func adjust(by seconds: TimeInterval) {
        scrubProgress = nil
        seek(to: currentTime + seconds)
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
