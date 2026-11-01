import Foundation

/// Which copy of LokalBot owns a set of local helpers. Each copy gets its own
/// llama-server ports and its own folder for helper binaries, PID markers and
/// bearer tokens, so a helper one copy leaves behind cannot hold a port the
/// installed app needs. (2026-10-09: an orphaned UI Test Host embedder held
/// 17873 for days and the installed app's embeddings silently stopped.)
enum LocalRuntimeOwner: CaseIterable, Sendable {
    /// The installed app, its embedded CLI, and release-identity builds run
    /// from Xcode build products.
    case release
    case development
    case uiTestHost
    /// The LokalBotTests host. It carries the release bundle id, so only this
    /// case keeps it away from the installed app's helpers and markers.
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

    /// Added to every release port. Blocks of ten leave room for new roles.
    var portOffset: Int {
        switch self {
        case .release: 0
        case .development: 10
        case .uiTestHost: 20
        case .unitTests: 30
        }
    }
}

/// The bundled llama-server instances. Ports follow the owning copy; residency
/// ids follow the role, so the model ledger and the Resource Monitor read the
/// same in every copy.
enum LlamaServerRole: String, CaseIterable, Sendable {
    case main
    case embedder
    case cotyping
    case graniteASR = "granite-asr"
    /// EmbeddingGemma 2 with its image and audio projector, for indexing the
    /// folders chosen under Files. Searches embed their words on `embedder`.
    case mediaEmbedder = "media-embedder"

    /// The installed app's ports. The CLI, MCP clients and DEVELOPMENT.md
    /// rely on them, so they never move.
    var releasePort: Int {
        switch self {
        case .main: 17_872
        case .embedder: 17_873
        case .cotyping: 17_874
        case .graniteASR: 17_875
        case .mediaEmbedder: 17_876
        }
    }

    func port(for owner: LocalRuntimeOwner) -> Int {
        releasePort + owner.portOffset
    }

    /// This process's port for the role.
    var port: Int { port(for: .current) }

    /// The role's row in the model-memory ledger (`ModelResidency`).
    var residencyID: String { "llama-server:\(rawValue)" }

    init?(residencyID: String) {
        guard let role = Self.allCases.first(where: { $0.residencyID == residencyID }) else {
            return nil
        }
        self = role
    }
}
