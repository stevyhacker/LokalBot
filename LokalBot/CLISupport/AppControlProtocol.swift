import Foundation

/// The CLI's requests to the running app over the control socket: one JSON
/// object per line, one request per connection. See
/// Docs/cli-configuration-design-2026-10-17.md.
enum AppControlProtocol {
    static let version = 1
    static let maximumMessageBytes = 1_048_576

    /// Passed by `lokalbot-cli` when it starts the app for a request, so the
    /// app comes up in the menu bar like a login launch instead of opening
    /// its main window.
    static let backgroundLaunchArgument = "--lokalbot-background-launch"

    static func isBackgroundLaunch(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        arguments.contains(backgroundLaunchArgument)
    }

    /// Settings sections `open settings <name>` accepts besides setting keys.
    static let settingsDestinations = [
        "models", "permissions", "agentAccess", "screenMemoryAccess", "personalContextAccess",
        "settingsControlAccess", "memoryHealth", "resourceMonitor", "autocompleteStatistics",
        "dictationWritingProfile",
    ]

    enum Method: String, CaseIterable {
        case hello
        case settingsList = "settings.list"
        case settingsGet = "settings.get"
        case settingsSet = "settings.set"
        case settingsRequest = "settings.request"
        case secretList = "secret.list"
        case secretSet = "secret.set"
        case secretClear = "secret.clear"
        case setupPlan = "setup.plan"
        case setupFinish = "setup.finish"
        case modelsStatus = "models.status"
        case modelsPreset = "models.preset"
        case modelsDownload = "models.download"
        case modelsCancel = "models.cancel"
        case permissionsList = "permissions.list"
        case permissionsRequest = "permissions.request"
        case launchAtLogin = "app.launchAtLogin"
        case restart = "app.restart"
        case doctor
        case status
        case open
    }

    /// Names `permissions request` accepts.
    static let permissionNames = ["microphone", "accessibility", "screen-recording", "input-monitoring", "calendar"]

    /// Model presets `models preset` and setup plans accept.
    static let modelPresets = ["recommended", "lightweight"]
}

struct AppControlRequest: Codable, Equatable {
    var protocolVersion: Int
    var method: String
    var params: [String: JSONValue]?

    init(method: AppControlProtocol.Method, params: [String: JSONValue]? = nil) {
        self.init(protocolVersion: AppControlProtocol.version, method: method.rawValue, params: params)
    }

    init(protocolVersion: Int, method: String, params: [String: JSONValue]?) {
        self.protocolVersion = protocolVersion
        self.method = method
        self.params = params
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case method
        case params
    }
}

/// A stable error the CLI prints as `[code] message`, like the MCP tools'
/// `[access_disabled]`.
struct AppControlError: Codable, Equatable, LocalizedError {
    var code: String
    var message: String
    /// Structured detail an agent can act on, such as the changes that need
    /// approval.
    var details: JSONValue?

    var errorDescription: String? { "[\(code)] \(message)" }

    static let settingsAccessDisabled = AppControlError(
        code: "settings_access_disabled", message: SettingsControlGate.disabledMessage)

    static func unknownKey(_ key: String) -> AppControlError {
        AppControlError(
            code: "unknown_key",
            message: "No setting is named \(key). Run `lokalbot-cli config search <words>` to find one.")
    }

    static func invalidValue(_ key: String, _ message: String) -> AppControlError {
        AppControlError(code: "invalid_value", message: "\(key) \(message).")
    }

    static func readOnly(_ keys: [String]) -> AppControlError {
        AppControlError(
            code: "read_only",
            message: "\(keys.joined(separator: ", ")) can't be changed from the terminal.",
            details: .array(keys.map(JSONValue.string)))
    }

    /// A widening change, or a new API key, waits for the person in LokalBot.
    /// `details` is the request as `settings.request` reports it.
    static func needsApproval(_ request: JSONValue, asking what: String) -> AppControlError {
        let id = request["id"]?.stringValue ?? "<id>"
        return AppControlError(
            code: "needs_approval",
            message: "\(what) needs the person's approval in LokalBot, so the request is waiting there. "
                + "Nothing changes unless they approve it. "
                + "Run `lokalbot-cli config request \(id) --wait 120` for the answer.",
            details: request)
    }

    static let denied = AppControlError(
        code: "denied",
        message: "The person declined this request in LokalBot. Nothing was changed. Don't ask again unless they say so.")

    static let expired = AppControlError(
        code: "expired",
        message: "Nobody answered this request in LokalBot before it expired. Nothing was changed.")

    static func unknownRequest(_ id: String) -> AppControlError {
        AppControlError(
            code: "unknown_request",
            message: "LokalBot has no request \(id). Requests are forgotten 30 minutes after they're answered, "
                + "and when LokalBot quits.")
    }

    static let tooManyRequests = AppControlError(
        code: "too_many_requests",
        message: "Requests are already waiting for the person in LokalBot. Wait for them to be answered first.")

    static func unknownSecret(_ name: String) -> AppControlError {
        AppControlError(
            code: "unknown_secret",
            message: "No API key is named \(name). Choose one of: "
                + AppSecret.allCases.map(\.rawValue).joined(separator: ", ") + ".")
    }

    static func invalidRequest(_ message: String) -> AppControlError {
        AppControlError(code: "invalid_request", message: message)
    }

    static func unknownMethod(_ method: String) -> AppControlError {
        AppControlError(code: "unknown_method", message: "LokalBot does not handle \(method).")
    }

    static let unsupportedProtocol = AppControlError(
        code: "app_outdated",
        message: "The running LokalBot does not understand this lokalbot-cli. Restart LokalBot to finish updating it.")

    static func appNotRunning(_ reason: String) -> AppControlError {
        AppControlError(code: "app_not_running", message: reason)
    }

    static let appNotResponding = AppControlError(
        code: "app_not_responding",
        message: "LokalBot is running but did not answer. If it was just updated, restart it.")
}

struct AppControlResponse: Codable, Equatable {
    var protocolVersion: Int
    var result: JSONValue?
    var error: AppControlError?

    static func success(_ result: JSONValue) -> AppControlResponse {
        AppControlResponse(protocolVersion: AppControlProtocol.version, result: result, error: nil)
    }

    static func failure(_ error: AppControlError) -> AppControlResponse {
        AppControlResponse(protocolVersion: AppControlProtocol.version, result: nil, error: error)
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case result
        case error
    }
}
