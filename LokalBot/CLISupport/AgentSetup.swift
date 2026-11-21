import Foundation

enum AgentSetup {
    static let launchArgument = "--lokalbot-agent-setup"
    static let notificationName = "me.dotenv.LokalBot.agent-setup-requested"
    static let lifetime: TimeInterval = 5 * 60
    static let maximumFileBytes = 16_384

    enum Grant: String, Codable, CaseIterable {
        case settings
        case meetingLibrary
        case screenMemory
        case files
    }

    struct Request: Codable, Equatable {
        var version = 1
        var nonce: String
        var requester: String
        var grants: [Grant]
        var createdAt: Date
        var expiresAt: Date

        func isLive(at date: Date = Date()) -> Bool {
            version == 1 && !nonce.isEmpty && grants.contains(.settings)
                && createdAt <= date.addingTimeInterval(60) && date < expiresAt
                && expiresAt.timeIntervalSince(createdAt) <= AgentSetup.lifetime + 1
        }
    }

    struct Answer: Codable, Equatable {
        var nonce: String
        var state: SettingsRequestState
        var grants: [Grant]
        var answeredAt: Date
    }

    static func requestURL(controlDirectory: URL) -> URL {
        controlDirectory.appendingPathComponent("setup-request.json")
    }

    static func answerURL(controlDirectory: URL) -> URL {
        controlDirectory.appendingPathComponent("setup-answer.json")
    }

    static func isLaunch(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        arguments.contains(launchArgument)
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue, size <= maximumFileBytes,
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum ProcessAncestry {
    static func describe(pid: Int32) -> String? {
        guard let name = processName(pid) else { return nil }
        var ancestor = parent(of: pid)
        for _ in 0..<6 {
            guard let current = ancestor else { break }
            if let parentName = processName(current), !shells.contains(parentName) {
                return "\(name) via \(parentName)"
            }
            ancestor = parent(of: current)
        }
        return name
    }

    private static let shells: Set<String> = [
        "zsh", "bash", "sh", "fish", "dash", "login", "env", "sudo", "timeout", "nohup", "tmux", "screen",
    ]

    private static func processName(_ pid: Int32) -> String? {
        #if os(macOS)
        var buffer = [CChar](repeating: 0, count: 4_096)
        let result = buffer.withUnsafeMutableBufferPointer { pointer in
            proc_pidpath(pid, pointer.baseAddress, UInt32(pointer.count))
        }
        guard result > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).lastPathComponent
        #else
        guard let path = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(pid)/exe") else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
        #endif
    }

    private static func parent(of pid: Int32) -> Int32? {
        #if os(macOS)
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let parent = Int32(info.pbi_ppid)
        return parent > 1 ? parent : nil
        #else
        guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let close = stat.lastIndex(of: ")") else { return nil }
        let fields = stat[stat.index(after: close)...].split(separator: " ")
        guard fields.count > 1, let parent = Int32(fields[1]) else { return nil }
        return parent > 1 ? parent : nil
        #endif
    }
}

struct SetupPlan: Codable, Equatable {
    static let keys = [
        "autoRecordMode", "calendarDetectionEnabled", "transcriptionLanguage", "summaryLanguage", "noteTemplate",
        "trackingEnabled", "screenContextCaptureMode", "codingAgentEvidenceEnabled",
        "dayDigestAutoEnabled", "dreamingEnabled",
        "dictationEnabled", "cotypingEnabled", "menuBarOnly", "appLanguage",
    ]

    var settings: [String: JSONValue]
    var models: String?
    var launchAtLogin: Bool?

    init(settings: [String: JSONValue] = [:], models: String? = nil, launchAtLogin: Bool? = nil) {
        self.settings = settings
        self.models = models
        self.launchAtLogin = launchAtLogin
    }

    init(json: JSONValue) throws {
        guard let object = json.objectValue else {
            throw AppControlError.invalidRequest("A setup plan is a JSON object with \"settings\", \"models\", and \"launchAtLogin\".")
        }
        settings = object["settings"]?.objectValue ?? [:]
        models = object["models"]?.stringValue
        if case .bool(let value)? = object["launchAtLogin"] { launchAtLogin = value }
        if let models, !AppControlProtocol.modelPresets.contains(models) {
            throw AppControlError.invalidRequest(
                "\"models\" must be one of: \(AppControlProtocol.modelPresets.joined(separator: ", ")).")
        }
        guard !settings.isEmpty || models != nil || launchAtLogin != nil else {
            throw AppControlError.invalidRequest("The setup plan changes nothing.")
        }
    }

    var json: JSONValue {
        var object: [String: JSONValue] = ["settings": .object(settings)]
        if let models { object["models"] = .string(models) }
        if let launchAtLogin { object["launchAtLogin"] = .bool(launchAtLogin) }
        return .object(object)
    }
}
