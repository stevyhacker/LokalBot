import Foundation

/// One visual scene in Rewind. Adjacent perceptually similar captures collapse
/// into a single frame while retaining every underlying snapshot for counts and
/// range deletion.
struct ScreenRewindFrame: Identifiable, Equatable, Sendable {
    private(set) var screenshots: [ActivityStore.Screenshot]

    var screenshot: ActivityStore.Screenshot { screenshots.last! }
    var id: Int64 { screenshot.id }
    var duplicateCount: Int { screenshots.count }

    init(screenshot: ActivityStore.Screenshot) {
        screenshots = [screenshot]
    }

    mutating func append(_ screenshot: ActivityStore.Screenshot) {
        screenshots.append(screenshot)
    }
}

enum ScreenRewindSequence {
    /// Oldest-first visual scenes, collapsing only adjacent captures in the
    /// same persisted similarity group.
    static func frames(from screenshots: [ActivityStore.Screenshot]) -> [ScreenRewindFrame] {
        var frames: [ScreenRewindFrame] = []
        for screenshot in screenshots.sorted(by: { $0.ts < $1.ts }) {
            if let group = screenshot.similarityGroupID,
               frames.last?.screenshot.similarityGroupID == group {
                frames[frames.count - 1].append(screenshot)
            } else {
                frames.append(ScreenRewindFrame(screenshot: screenshot))
            }
        }
        return frames
    }

    static func clampedIndex(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index, 0), count - 1)
    }

    /// Half-open interval covering the selected frame range. The tiny trailing
    /// epsilon includes the final capture in ActivityStore's `< end` queries.
    static func deletionInterval(frames: [ScreenRewindFrame],
                                 firstIndex: Int, lastIndex: Int) -> DateInterval? {
        guard !frames.isEmpty else { return nil }
        let first = clampedIndex(min(firstIndex, lastIndex), count: frames.count)
        let last = clampedIndex(max(firstIndex, lastIndex), count: frames.count)
        let covered = frames[first...last].flatMap(\.screenshots)
        guard let start = covered.map(\.ts).min(), let final = covered.map(\.ts).max() else {
            return nil
        }
        return DateInterval(start: start, end: final.addingTimeInterval(0.001))
    }

    static func captureCount(frames: [ScreenRewindFrame],
                             firstIndex: Int, lastIndex: Int) -> Int {
        guard !frames.isEmpty else { return 0 }
        let first = clampedIndex(min(firstIndex, lastIndex), count: frames.count)
        let last = clampedIndex(max(firstIndex, lastIndex), count: frames.count)
        return frames[first...last].reduce(0) { $0 + $1.duplicateCount }
    }
}
