import Foundation

enum DiarizationModel: String, Codable, CaseIterable, Identifiable, Sendable {
    case community1
    case nemotron3

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .community1: "Pyannote Community-1"
        case .nemotron3: "Nemotron 3 (Preview)"
        }
    }

    var description: String {
        switch self {
        case .community1:
            "Separates voices locally after recording. Downloads speaker models from Hugging Face on first use."
        case .nemotron3:
            "Separates up to 8 voices locally after recording, including overlapping speech. First use downloads about 200 MB from Hugging Face. Remembering voices also uses the Pyannote models."
        }
    }

    /// Invalidate partial transcripts when the model, weights, or turn policy changes.
    var checkpointIdentity: String {
        switch self {
        case .community1: "community1-tuned-fluidaudio-0.17.1-v1"
        case .nemotron3: "nemotron3-offline-\(NemotronDiarizationModels.revision)-threshold0.5-min0.2-v1"
        }
    }
}
