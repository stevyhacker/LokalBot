import Foundation

struct WaveformViewport: Equatable, Sendable {
    static let minZoom: Double = 1.0
    static let maxZoom: Double = 30.0

    private(set) var windowStart: TimeInterval
    private(set) var windowEnd: TimeInterval
    private(set) var zoom: Double
    private(set) var visibleStart: TimeInterval

    init(
        windowStart: TimeInterval = 0,
        windowEnd: TimeInterval = 0,
        zoom: Double = 1.0,
        visibleStart: TimeInterval? = nil
    ) {
        let safeStart = max(0, windowStart.isFinite ? windowStart : 0)
        let safeEnd = windowEnd.isFinite ? max(safeStart, windowEnd) : safeStart
        self.windowStart = safeStart
        self.windowEnd = safeEnd
        self.zoom = Self.clampZoom(zoom)
        self.visibleStart = visibleStart ?? safeStart
        clamp()
    }

    var totalSpan: TimeInterval { max(0, windowEnd - windowStart) }
    var visibleSpan: TimeInterval { totalSpan > 0 ? totalSpan / zoom : 0 }
    var visibleEnd: TimeInterval { min(windowEnd, visibleStart + visibleSpan) }

    static func clampZoom(_ value: Double) -> Double {
        guard value.isFinite else { return minZoom }
        return min(maxZoom, max(minZoom, value))
    }

    mutating func updateBounds(windowStart: TimeInterval, windowEnd: TimeInterval) {
        let safeStart = max(0, windowStart.isFinite ? windowStart : 0)
        let safeEnd = windowEnd.isFinite ? max(safeStart, windowEnd) : safeStart
        if safeStart == self.windowStart, safeEnd == self.windowEnd { return }
        self.windowStart = safeStart
        self.windowEnd = safeEnd
        clamp()
    }

    mutating func clamp() {
        zoom = Self.clampZoom(zoom)
        let span = visibleSpan
        let maxStart = max(windowStart, windowEnd - span)
        if !visibleStart.isFinite { visibleStart = windowStart }
        visibleStart = min(maxStart, max(windowStart, visibleStart))
    }

    func time(atFraction fraction: Double) -> TimeInterval {
        let clamped = WaveformAnalysis.clamp(fraction)
        return visibleStart + clamped * visibleSpan
    }

    func fraction(at time: TimeInterval) -> Double {
        guard visibleSpan > 0, time.isFinite else { return 0 }
        return (time - visibleStart) / visibleSpan
    }

    mutating func zoom(by factor: Double, anchorFraction: Double) {
        guard totalSpan > 0, factor.isFinite, factor > 0 else { return }
        let clampedAnchor = WaveformAnalysis.clamp(anchorFraction)
        let anchorTime = time(atFraction: clampedAnchor)
        let newZoom = Self.clampZoom(zoom * factor)
        guard newZoom != zoom else { return }
        zoom = newZoom
        visibleStart = anchorTime - clampedAnchor * visibleSpan
        clamp()
    }

    mutating func pan(by deltaSeconds: TimeInterval) {
        guard totalSpan > 0, deltaSeconds.isFinite else { return }
        visibleStart += deltaSeconds
        clamp()
    }

    mutating func reset() {
        zoom = Self.minZoom
        visibleStart = windowStart
        clamp()
    }
}

struct WaveformSelectionState: Equatable, Sendable {
    static let minimumRangeDuration: TimeInterval = 0.25

    var pendingStart: TimeInterval?
    var selection: Meeting.ContentRange?

    mutating func handleLeftClick(at rawTime: TimeInterval, bounds: ClosedRange<TimeInterval>) {
        guard rawTime.isFinite else { return }
        let time = min(bounds.upperBound, max(bounds.lowerBound, rawTime))
        if selection != nil {
            selection = nil
            pendingStart = time
            return
        }
        guard let startAnchor = pendingStart else {
            pendingStart = time
            return
        }
        let lower = min(startAnchor, time)
        let upper = max(startAnchor, time)
        if upper - lower >= Self.minimumRangeDuration {
            selection = Meeting.ContentRange(start: lower, end: upper)
            pendingStart = nil
        } else {
            pendingStart = time
        }
    }

    mutating func clear() {
        pendingStart = nil
        selection = nil
    }
}
