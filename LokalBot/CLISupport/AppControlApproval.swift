import Foundation

/// Where a request that needs the person stands, as `settings.request`
/// reports it.
enum SettingsRequestState: String, Codable, CaseIterable {
    case pending
    case approved
    case denied
    case expired
}

/// The API keys `lokalbot-cli secret` can set. Keys are write-only from the
/// terminal: the CLI can say whether one is saved, never read it back.
enum AppSecret: String, CaseIterable, Codable {
    case openAICompatible = "openai-compatible"
    case remoteTranscription = "remote-transcription"
    case autocompleteServer = "autocomplete-server"

    var title: String {
        switch self {
        case .openAICompatible: "OpenAI-compatible server API key"
        case .remoteTranscription: "Transcription server API key"
        case .autocompleteServer: "Autocomplete server API key"
        }
    }

    var summary: String {
        switch self {
        case .openAICompatible:
            "Sent with Think requests to the OpenAI-compatible server in Settings → Models. "
                + "The transcription server uses it too when it has no key of its own."
        case .remoteTranscription:
            "Sent with transcription requests to the server in Settings → Models."
        case .autocompleteServer:
            "Sent with autocomplete requests to the server in Settings → Models."
        }
    }

    /// The last four characters, so the person can tell which key they are
    /// approving without seeing it.
    static func hint(for value: String) -> String {
        value.count > 8 ? "…" + value.suffix(4) : ""
    }
}
