import Foundation

enum LocalRuntimeOwner: CaseIterable, Sendable {
    case release
    case development
    case uiTestHost
    case unitTests

    static let current = resolve(identity: AppIdentifiers.identity,
                                 isUnitTesting: UITestRuntime.isUnitTesting)

    static func resolve(identity: AppIdentifiers.Identity, isUnitTesting: Bool) -> Self {
        if isUnitTesting { return .unitTests }
        switch identity {
        case .release: return .release
        case .development: return .development
        case .uiTestHost: return .uiTestHost
        }
    }

    var portOffset: Int {
        switch self {
        case .release: 0
        case .development: 10
        case .uiTestHost: 20
        case .unitTests: 30
        }
    }
}

enum LlamaServerRole: String, CaseIterable, Sendable {
    case main
    case embedder
    case cotyping
    case graniteASR = "granite-asr"
    case mediaEmbedder = "media-embedder"
    case qwenASR = "qwen-asr"
    case qwenASRCompact = "qwen-asr-compact"

    var releasePort: Int {
        switch self {
        case .main: 17_872
        case .embedder: 17_873
        case .cotyping: 17_874
        case .graniteASR: 17_875
        case .mediaEmbedder: 17_876
        case .qwenASR: 17_877
        case .qwenASRCompact: 17_878
        }
    }

    func port(for owner: LocalRuntimeOwner) -> Int {
        releasePort + owner.portOffset
    }

    var port: Int { port(for: .current) }

    var residencyID: String { "llama-server:\(rawValue)" }

    init?(residencyID: String) {
        guard let role = Self.allCases.first(where: { $0.residencyID == residencyID }) else {
            return nil
        }
        self = role
    }
}
