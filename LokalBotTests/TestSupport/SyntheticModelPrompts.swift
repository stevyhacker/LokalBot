import Foundation
@testable import LokalBot

/// Fixed, synthetic inputs sent to real models by the recorder. Nothing here
/// comes from a real library; changing it invalidates committed recordings.
enum SyntheticModelPrompts {
    static let askQuestion = "What did we decide about the caching layer, and who owns the next step?"

    static func digestEvidence(calendar: Calendar) -> DayDigestEvidence {
        func time(_ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 4, hour: hour, minute: minute))!
        }
        let blocks = [
            ActivityBlock(id: 1, app: "Xcode", title: "EvictionPolicy.swift", start: time(9), end: time(10, 30)),
            ActivityBlock(id: 2, app: "Google Chrome", title: "Pull request #42 - caching layer",
                          start: time(10, 30), end: time(11, 15)),
            ActivityBlock(id: 3, app: "Terminal", title: "load harness", start: time(14), end: time(15, 30)),
        ]
        let contexts = [
            DayScreenContext(snapshotID: 11, capturedAt: time(9, 20), app: "Xcode", windowTitle: "EvictionPolicy.swift",
                             text: "func evict(olderThan cutoff: Date) — LRU eviction for the Redis cache; tests: 12 passed"),
            DayScreenContext(snapshotID: 12, capturedAt: time(10, 45), app: "Google Chrome",
                             windowTitle: "Pull request #42 - caching layer",
                             text: "Review: approve after benchmarking failover latency. Merge blocked on cluster mode decision."),
            DayScreenContext(snapshotID: 13, capturedAt: time(14, 40), app: "Terminal", windowTitle: "load harness",
                             text: "failover p95 1.8s → 0.9s after connection pool change; benchmark complete"),
        ]
        return DayDigestEvidence.build(day: time(12), blocks: blocks, screenContexts: contexts,
                                       meetings: [], calendar: calendar)
    }

    static func standupTranscript() -> Transcript {
        let lines: [(TimeInterval, TimeInterval, String, String)] = [
            (0, 12, "me", "Let's lock the caching layer. I propose Redis for the pub-sub support."),
            (12, 26, "them", "Agreed on Redis. Open question: do we need cluster mode from day one?"),
            (26, 38, "me", "I'll draft the eviction-policy doc by Thursday."),
            (38, 52, "them", "Please benchmark failover latency before we commit to a cluster."),
            (52, 66, "me", "Fair. I'll borrow the load harness from the search team for that."),
        ]
        return Transcript(segments: lines.map {
            Transcript.Segment(start: $0.0, end: $0.1, speaker: $0.2, text: $0.3)
        }, engine: "synthetic")
    }

    /// A standup the way it is actually transcribed: little punctuation,
    /// stumbled words, and one speaker's sentence cut across rows. The user
    /// commits to two things mid-sentence; neither starts with "I'll".
    static func runOnStandupTranscript() -> Transcript {
        let lines: [(TimeInterval, TimeInterval, String, String)] = [
            (0, 6, "them", "okay who wants to go next"),
            (7, 12, "me", "On my side I've been drafting that small export proof of concept and also had a few "
                + "comments to respond to on the the billing change"),
            (12.2, 13, "me", "one"),
            (13.4, 19, "me", "so it just video is not working for me right now anyway so these"),
            (19.2, 19.3, "me", "The"),
            (19.4, 24, "me", "export change is something I I have to update"),
            (24.1, 28, "me", "and confirm the the plan is still"),
            (28.2, 31, "me", "true because it was initially written"),
            (31.1, 35, "me", "before the last merges so"),
            (35.2, 42, "me", "I would say it needs a bit of a revisit right now the nightly export is a separate queue"),
            (42.2, 46, "me", "from the the main queue so I think"),
            (46.3, 58, "me", "those can be a bit more simplified if we update the plan but I'll ping you Mira and Jonas "
                + "to to get that resolved in chat"),
            (59, 66, "them", "sounds good and from the reporting side Nico reviewed the two open changes I had so "
                + "I'm going to merge them"),
            (66.5, 74, "them", "one more thing we need to do is once the pricing work is merged speak with Mira and "
                + "figure out which alerts we still need"),
        ]
        return Transcript(segments: lines.map {
            Transcript.Segment(start: $0.0, end: $0.1, speaker: $0.2, text: $0.3)
        }, engine: "synthetic")
    }
}
