import Foundation

/// Finds passages from earlier meetings that the newest live lines may agree
/// or conflict with. Search runs on this Mac; only the passages it returns
/// are added to the radar request.
@MainActor
protocol RadarEvidenceSource: AnyObject {
    func evidence(for text: String, meeting: Meeting, limit: Int) async -> [RadarEvidence]
}

/// Keyword search over transcripts, summaries, and saved outcomes, plus the
/// semantic index when it is on, limited to meetings that started before the
/// one being recorded.
@MainActor
final class LibraryRadarEvidenceSource: RadarEvidenceSource {
    private let meetings: () -> [Meeting]
    private let searchIndex: SearchIndex
    private let embeddingIndex: EmbeddingIndex
    private let settings: () -> AppSettings

    static let maximumPassageCharacters = 280
    /// Enough of the newest speech to find the topic without diluting it.
    static let maximumQueryCharacters = 600

    init(meetings: @escaping () -> [Meeting], searchIndex: SearchIndex,
         embeddingIndex: EmbeddingIndex, settings: @escaping () -> AppSettings) {
        self.meetings = meetings
        self.searchIndex = searchIndex
        self.embeddingIndex = embeddingIndex
        self.settings = settings
    }

    func evidence(for text: String, meeting: Meeting, limit: Int) async -> [RadarEvidence] {
        let query = String(text.suffix(Self.maximumQueryCharacters))
        let earlier = meetings().filter {
            $0.id != meeting.id && $0.startedAt < meeting.startedAt && $0.isOwnWork && $0.endedAt != nil
        }
        guard !earlier.isEmpty, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let byID = Dictionary(earlier.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let allowed = Set(byID.keys)

        var found: [RadarEvidence] = []
        var seen = Set<String>()
        func add(_ meetingID: UUID, time: TimeInterval?, speaker: String?, text: String) {
            guard let source = byID[meetingID] else { return }
            let key = "\(meetingID)-\(Int(time ?? -1))"
            let passage = Self.passage(text)
            guard !passage.isEmpty, seen.insert(key).inserted else { return }
            found.append(RadarEvidence(meetingID: meetingID, meetingTitle: source.displayTitle,
                                       meetingDate: source.startedAt, time: time,
                                       speaker: speaker.flatMap { $0.isEmpty ? nil : SpeakerDisplayName.label($0) },
                                       text: passage))
        }

        // Saved decisions and actions first: they are what a new line most
        // often contradicts.
        let keyword = searchIndex.search(query, limit: limit * 2, matchAll: false,
                                         dropStopWords: true, meetingIDs: allowed)
        for hit in keyword.sorted(by: { Self.rank($0.kind) < Self.rank($1.kind) }) where hit.kind != .title {
            add(hit.meetingID, time: hit.kind == .segment ? hit.start : nil,
                speaker: hit.kind == .segment ? hit.speaker : nil,
                text: hit.sourceText ?? hit.snippet)
        }
        if settings().semanticSearchEnabled, embeddingIndex.hasEmbeddings {
            for hit in await embeddingIndex.search(query, limit: limit, meetingIDs: allowed, priority: .interactive) {
                add(hit.meetingID, time: hit.start > 0 ? hit.start : nil, speaker: nil, text: hit.text)
            }
        }
        return Array(found.prefix(limit))
    }

    private static func rank(_ kind: SearchIndex.Kind) -> Int {
        switch kind {
        case .outcome: 0
        case .segment: 1
        case .summary: 2
        case .notes: 3
        case .title: 4
        }
    }

    static func passage(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "«", with: "").replacingOccurrences(of: "»", with: "")
            .split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > maximumPassageCharacters else { return flat }
        return String(flat.prefix(maximumPassageCharacters)) + "…"
    }
}
