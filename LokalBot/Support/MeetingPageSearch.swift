import Foundation

struct MeetingPageSearchMatch: Equatable {
    enum Section: Hashable {
        case meetingDetails
        case meetingStatus
        case actionItems
        case decisions
        case notes
        case summary
        case transcript

        var label: String {
            switch self {
            case .meetingDetails: "Meeting details"
            case .meetingStatus: "Meeting status"
            case .actionItems: "Action items"
            case .decisions: "Decisions"
            case .notes: "Notes"
            case .summary: "Summary"
            case .transcript: "Transcript"
            }
        }
    }

    enum MeetingMetadataField: Hashable {
        case date
        case duration
        case app
        case audioSource
    }

    enum ActionField: Hashable {
        case text
        case owner
        case due
        case evidence
    }

    enum DecisionField: Hashable {
        case text
        case evidence
    }

    enum TranscriptField: Hashable {
        case timestamp
        case speaker
        case text
    }

    enum Location: Hashable {
        case title
        case meetingMetadata(MeetingMetadataField)
        case processingStatus
        case exportError
        case speechError
        case sectionHeader(Section)
        case emptyState(Section)
        case action(id: String, field: ActionField)
        case decision(id: String, field: DecisionField)
        case notesLabel
        case notes
        case summaryMetadata
        case summary
        case transcriptEngine
        case transcript(segmentIndex: Int, field: TranscriptField)

        var sectionLabel: String {
            switch self {
            case .title, .meetingMetadata:
                Section.meetingDetails.label
            case .processingStatus, .exportError, .speechError:
                Section.meetingStatus.label
            case let .sectionHeader(section), let .emptyState(section):
                section.label
            case .action:
                Section.actionItems.label
            case .decision:
                Section.decisions.label
            case .notesLabel, .notes:
                Section.notes.label
            case .summaryMetadata, .summary:
                Section.summary.label
            case .transcriptEngine, .transcript:
                Section.transcript.label
            }
        }

        var requiresTranscriptExpansion: Bool {
            switch self {
            case .transcriptEngine, .transcript, .emptyState(.transcript):
                true
            default:
                false
            }
        }
    }

    let location: Location
    let occurrenceIndex: Int
}

struct MeetingPageSearchSource: Equatable {
    let location: MeetingPageSearchMatch.Location
    let text: String
}

enum MeetingPageSearch {
    static func matches(
        query: String,
        sources: [MeetingPageSearchSource]
    ) -> [MeetingPageSearchMatch] {
        guard !normalizedQuery(query).isEmpty else { return [] }

        var result: [MeetingPageSearchMatch] = []
        for source in sources {
            appendMatches(
                in: source.text,
                at: source.location,
                query: query,
                to: &result)
        }
        return result
    }

    static func ranges(in text: String, query: String) -> [Range<String.Index>] {
        let needle = normalizedQuery(query)
        guard !needle.isEmpty, !text.isEmpty else { return [] }

        var result: [Range<String.Index>] = []
        var lowerBound = text.startIndex
        while lowerBound < text.endIndex,
              let range = text.range(
                of: needle,
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                range: lowerBound..<text.endIndex,
                locale: .current) {
            result.append(range)
            lowerBound = range.upperBound
        }
        return result
    }

    private static func normalizedQuery(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func appendMatches(
        in text: String,
        at location: MeetingPageSearchMatch.Location,
        query: String,
        to result: inout [MeetingPageSearchMatch]
    ) {
        for index in ranges(in: text, query: query).indices {
            result.append(.init(location: location, occurrenceIndex: index))
        }
    }
}
