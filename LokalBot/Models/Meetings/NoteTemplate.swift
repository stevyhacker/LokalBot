import Foundation

/// Shape of the notes the LLM should produce. Adapted from Seminarly's
/// `NoteTemplate` — LokalBot keeps summarisation output as Markdown rather
/// than structured JSON, so the JSON section schema isn't ported, just the
/// enum that drives prompt selection.
enum NoteTemplate: String, Codable, CaseIterable, Identifiable, Sendable {
    case meeting
    case lecture
    case studyGuide
    case podcast
    case freeform

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .meeting: return "Meeting"
        case .lecture: return "Lecture"
        case .studyGuide: return "Study guide"
        case .podcast: return "Podcast / interview"
        case .freeform: return "Free-form"
        }
    }

    /// One-line summary used in the Settings picker.
    var description: String {
        switch self {
        case .meeting:
            return "TL;DR · Key points · Decisions · Action items · Open questions"
        case .lecture:
            return "TL;DR · Concepts · Definitions · Examples · Questions to review · Action items"
        case .studyGuide:
            return "TL;DR · Key concepts · Flashcards · Practice questions · Action items"
        case .podcast:
            return "TL;DR · Topics · Quotes · Insights · Action items"
        case .freeform:
            return "Topical bullets · Action items"
        }
    }
}
