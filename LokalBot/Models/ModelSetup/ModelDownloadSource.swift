import Foundation

/// Where LokalBot fetches its pinned model files, chosen in Settings → Models.
///
/// huggingface.co is blocked in mainland China, so two opt-in sources serve the
/// same files there: HF-Mirror (hf-mirror.com), a community mirror with
/// Hugging Face's paths, and ModelScope (modelscope.cn), Alibaba's model hub.
/// Every file is still checked against the size and SHA-256 LokalBot pins, so a
/// source can make a download fail but cannot change a model. See
/// `ModelDownloadRouting`.
enum ModelDownloadSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case huggingFace
    case hfMirror
    case modelScope

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .huggingFace: "Hugging Face"
        case .hfMirror: "HF-Mirror (hf-mirror.com)"
        case .modelScope: "ModelScope (modelscope.cn)"
        }
    }

    var detail: String {
        switch self {
        case .huggingFace:
            "Downloads from huggingface.co, where the models are published."
        case .hfMirror:
            "A community mirror of Hugging Face that works in mainland China. If it fails, LokalBot tries Hugging Face."
        case .modelScope:
            "Alibaba's model hub in mainland China, for files it carries unchanged. Other files come from HF-Mirror, then Hugging Face."
        }
    }
}
