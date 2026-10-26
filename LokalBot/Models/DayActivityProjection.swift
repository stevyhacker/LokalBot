import Foundation

/// One definition of active time for every day surface: the union of valid,
/// non-system intervals, clipped to the selected civil day (including DST).
/// The day's coding-agent bursts, when there are any, name and cut the work
/// sessions by project.
struct DayActivityProjection {
    let blocks: [ActivityBlock]
    let sessions: [TimelineWorkSession]
    let activeSeconds: TimeInterval
    let perApp: [(key: String, value: TimeInterval)]
    let attribution: TimelineProjectAttribution

    init(
        blocks: [ActivityBlock],
        day: Date,
        agentBursts: [CodingAgentBurst] = [],
        calendar: Calendar = .current
    ) {
        let interval = ActivityStore.dayInterval(containing: day, calendar: calendar)
        self.blocks = blocks.compactMap { block in
            guard !TimelineWorkSession.isSystemOnly(app: block.app) else { return nil }
            let start = max(block.start, interval.start), end = min(block.end, interval.end)
            guard end > start else { return nil }
            return ActivityBlock(id: block.id, app: block.app, title: block.title, start: start, end: end)
        }
        attribution = TimelineProjectAttribution(bursts: agentBursts)
        sessions = TimelineWorkSession.sessions(from: self.blocks, attribution: attribution)
        activeSeconds = sessions.reduce(0) { $0 + $1.activeDuration }
        perApp = Dictionary(grouping: self.blocks, by: \.app).mapValues { blocks in
            TimelineWorkSession.mergedDuration(blocks)
        }.sorted { $0.value > $1.value }
    }
}
