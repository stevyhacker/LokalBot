import Foundation

/// Where the day's tracked time went, for Today and Timeline.
enum DayActivityOverview {
    /// Tracked time per app, busiest first, without system-only processes.
    static func perApp(_ blocks: [ActivityBlock]) -> [(label: String, seconds: TimeInterval)] {
        Dictionary(grouping: blocks.filter { !TimelineWorkSession.isSystemOnly(app: $0.app) }, by: \.app)
            .map { (label: $0.key, seconds: $0.value.reduce(0) { $0 + $1.duration }) }
            .sorted { $0.seconds > $1.seconds }
    }
}
