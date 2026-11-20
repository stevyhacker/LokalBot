import Foundation

enum DayActivityOverview {
    static func perApp(_ blocks: [ActivityBlock]) -> [(label: String, seconds: TimeInterval)] {
        Dictionary(grouping: blocks.filter { !TimelineWorkSession.isSystemOnly(app: $0.app) }, by: \.app)
            .map { (label: $0.key, seconds: $0.value.reduce(0) { $0 + $1.duration }) }
            .sorted { $0.seconds > $1.seconds }
    }
}
