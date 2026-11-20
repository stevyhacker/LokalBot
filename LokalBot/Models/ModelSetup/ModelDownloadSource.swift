import Foundation

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
