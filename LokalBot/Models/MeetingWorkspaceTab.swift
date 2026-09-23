import Foundation

enum MeetingWorkspaceTab: String, CaseIterable, Identifiable {
    case summary = "Summary"
    case transcript = "Transcript"
    case notes = "Notes"
    case review = "Review"
    var id: String { rawValue }

    static func containing(_ location: MeetingPageSearchMatch.Location) -> Self {
        switch location {
        case .summary, .summaryMetadata, .sectionHeader(.summary), .emptyState(.summary): .summary
        case .notes, .notesLabel, .sectionHeader(.notes), .emptyState(.notes): .notes
        case .transcript, .transcriptEngine, .sectionHeader(.transcript), .emptyState(.transcript): .transcript
        default: .summary
        }
    }
}
