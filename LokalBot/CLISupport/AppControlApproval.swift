import Foundation

enum SettingsRequestState: String, Codable, CaseIterable {
    case pending
    case approved
    case denied
    case expired
}

enum AppSecret: String, CaseIterable, Codable {
    case openAICompatible = "openai-compatible"
    case remoteTranscription = "remote-transcription"
    case autocompleteServer = "autocomplete-server"
    case metaModelAPI = "meta-model-api"

    var title: String {
        switch self {
        case .openAICompatible: "OpenAI-compatible server API key"
        case .remoteTranscription: "Transcription server API key"
        case .autocompleteServer: "Autocomplete server API key"
        case .metaModelAPI: "Meta Model API key"
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
        case .metaModelAPI:
            "Sent to api.meta.ai with fast live text audio (Settings → Meetings → Meta Muse)."
        }
    }

    static func hint(for value: String) -> String {
        value.count > 8 ? "…" + value.suffix(4) : ""
    }
}
