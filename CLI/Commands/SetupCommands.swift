import ArgumentParser
import Foundation

struct SetupCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Set LokalBot up for the person, with their approval in the app.",
        discussion: """
            start asks the person, in LokalBot, to let this agent change
            settings; it is the only way to ask. The rest needs that access:
            plan prints the settings to talk through, apply applies an agreed
            plan (consent changes go to one approval card), and finish closes
            onboarding. See AGENT_SETUP.md for the whole journey.

              lokalbot-cli setup start --wait 300
              lokalbot-cli setup plan > plan.json
              lokalbot-cli setup apply plan.json --wait 300
              lokalbot-cli setup finish
            """,
        subcommands: [
            SetupStartCommand.self, SetupPlanCommand.self, SetupApplyCommand.self,
            SetupFinishCommand.self, SetupLaunchAtLoginCommand.self,
        ])
}

struct SetupStartCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Ask the person to let this agent set up LokalBot.",
        discussion: """
            Leaves a request that LokalBot shows the person, starting LokalBot
            if needed. Read access to the meeting library or screen memory
            appears as separate boxes, off unless the person ticks them.
            Exits 0 when allowed, 3 while waiting, 4 when declined, and 5 when
            nobody answered in time.
            """)

    @Flag(name: .long, help: "Also ask for read access to the meeting library.")
    var meetingLibrary = false

    @Flag(name: .long, help: "Also ask for read access to screen memory.")
    var screenMemory = false

    @Option(name: .long, help: ArgumentHelp(
        "Seconds to wait for the person to answer (at most 300).", valueName: "seconds"))
    var wait: Double?

    func run() throws {
        let root = SessionLookup.storageRootURL
        let client = AppControlClient(root: root)
        var grants: [AgentSetup.Grant] = [.settings]
        if meetingLibrary, !AgentAccessGate(root: root).isEnabled { grants.append(.meetingLibrary) }
        if screenMemory, !ScreenMemoryAccessGate(root: root).isEnabled { grants.append(.screenMemory) }
        if client.gate.isEnabled, grants == [.settings] {
            print(ControlOutput.json(["state": "approved", "alreadyAllowed": true]))
            return
        }

        let control = client.gate.controlDirectory
        let now = Date()
        let request = AgentSetup.Request(
            nonce: UUID().uuidString,
            requester: ProcessAncestry.describe(pid: getpid()) ?? "lokalbot-cli",
            grants: grants,
            createdAt: now,
            expiresAt: now.addingTimeInterval(AgentSetup.lifetime))
        try? FileManager.default.removeItem(at: AgentSetup.answerURL(controlDirectory: control))
        try AgentSetup.write(request, to: AgentSetup.requestURL(controlDirectory: control))
        let hint = try Self.show(client: client)

        guard let wait, wait > 0 else {
            print(ControlOutput.json([
                "state": "pending",
                "expiresAt": .string(ISO8601DateFormatter().string(from: request.expiresAt)),
                "message": .string(hint ?? "Ask the person to answer the request in LokalBot. Run with --wait to wait for it."),
            ]))
            throw ApprovalExit.waiting
        }
        ControlOutput.standardError(hint ?? "Waiting for the person to answer in LokalBot…")
        let answer = Self.answer(to: request, control: control, seconds: min(wait, 300))
        var result: [String: JSONValue] = ["state": .string(answer?.state.rawValue ?? SettingsRequestState.pending.rawValue)]
        if let answer { result["grants"] = .array(answer.grants.map { .string($0.rawValue) }) }
        if answer?.state == .approved {
            // The socket opens right after the person allows it.
            result["appResponding"] = .bool(
                (try? client.request(.hello, launch: false, launchTimeout: 10)) != nil)
        }
        print(ControlOutput.json(.object(result)))
        if let exit = ControlOutput.exitCode(for: answer?.state.rawValue) { throw exit }
    }

    /// Opens LokalBot on the request, or tells a running copy to show it.
    /// Returns a hint when this CLI can't start LokalBot itself.
    private static func show(client: AppControlClient) throws -> String? {
        if client.isAppRunning {
            #if os(macOS)
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name(AgentSetup.notificationName), object: nil, userInfo: nil, deliverImmediately: true)
            #endif
            return nil
        }
        guard let app = AppControlClient.enclosingApp(forExecutable: Bundle.main.executableURL) else {
            return "This lokalbot-cli is not inside LokalBot.app, so it can't open LokalBot. Ask the person to open LokalBot; it shows the request at launch."
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [app.path, "--args", AgentSetup.launchArgument]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AppControlError.appNotRunning("Could not open LokalBot at \(app.path).")
        }
        return nil
    }

    private static func answer(to request: AgentSetup.Request, control: URL, seconds: Double) -> AgentSetup.Answer? {
        let deadline = Date().addingTimeInterval(seconds)
        let url = AgentSetup.answerURL(controlDirectory: control)
        while Date() < deadline {
            if let answer = AgentSetup.read(AgentSetup.Answer.self, from: url), answer.nonce == request.nonce {
                return answer
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return nil
    }
}

struct SetupPlanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plan",
        abstract: "Print a setup plan to agree with the person.",
        discussion: """
            The settings a setup covers, with their current values, the model
            preset suited to this Mac, and launch at login. Edit the values to
            the person's answers, then pass the file to setup apply. notes
            lists the settings whose change needs the person's approval.
            """)

    @Option(name: .long, help: "Model preset: recommended or lightweight. Defaults to the one suited to this Mac.")
    var preset: String?

    @OptionGroup var launch: AppLaunchOptions

    func run() throws {
        if let preset, !AppControlProtocol.modelPresets.contains(preset) {
            throw ValidationError("Choose a preset: \(AppControlProtocol.modelPresets.joined(separator: ", ")).")
        }
        print(ControlOutput.json(try launch.request(.setupPlan, params: preset.map { ["preset": .string($0)] })))
    }
}

struct SetupApplyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apply",
        abstract: "Apply an agreed setup plan.",
        discussion: """
            Starts the model preset, sets launch at login, and applies
            preferences right away. Changes that widen what LokalBot captures
            or sends go to one approval card in LokalBot. Exits 0 when
            everything applied, 3 while the card waits, 4 when the person
            declined it, and 5 when nobody answered in time.
            """)

    @Argument(help: "A plan from setup plan, or - for stdin.")
    var file: String

    @OptionGroup var approval: ApprovalWaitOptions

    @OptionGroup var launch: AppLaunchOptions

    func run() throws {
        let data = file == "-"
            ? FileHandle.standardInput.readDataToEndOfFile()
            : try Data(contentsOf: URL(fileURLWithPath: (file as NSString).expandingTildeInPath))
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw ValidationError("\(file) is not JSON.")
        }
        let plan = try SetupPlan(json: json)
        for key in plan.settings.keys { _ = try ControlOutput.requireSpec(key) }

        var report: [String: JSONValue] = [:]
        var exit: ExitCode?
        if let models = plan.models {
            report["models"] = try launch.request(.modelsPreset, params: ["preset": .string(models)])
        }
        if let launchAtLogin = plan.launchAtLogin {
            report["launchAtLogin"] = try launch.request(.launchAtLogin, params: ["enabled": .bool(launchAtLogin)])
        }
        if !plan.settings.isEmpty {
            let preview = try launch.request(
                .settingsSet, params: SettingsChangeRequest(changes: plan.settings, dryRun: true).params)
            var classes: [String: String] = [:]
            if case .array(let entries)? = preview["changes"] {
                for entry in entries {
                    if let key = entry["key"]?.stringValue { classes[key] = entry["change"]?.stringValue }
                }
            }
            let readOnly = classes.filter { $0.value == SettingChangeClass.readOnly.rawValue }.keys.sorted()
            guard readOnly.isEmpty else { throw AppControlError.readOnly(readOnly) }
            let direct = plan.settings.filter {
                classes[$0.key] == SettingChangeClass.preference.rawValue
                    || classes[$0.key] == SettingChangeClass.narrowing.rawValue
            }
            let consent = plan.settings.filter { classes[$0.key] == SettingChangeClass.widening.rawValue }
            if !direct.isEmpty {
                report["applied"] = try launch.request(.settingsSet, params: SettingsChangeRequest(changes: direct).params)
            }
            if !consent.isEmpty {
                do {
                    report["approval"] = try launch.request(.settingsSet, params: SettingsChangeRequest(changes: consent).params)
                } catch let error as AppControlError where error.code == "needs_approval" {
                    var request = error.details ?? .null
                    if let wait = approval.wait, wait > 0, let id = request["id"]?.stringValue {
                        ControlOutput.standardError("Waiting for the person to review the consent changes in LokalBot…")
                        request = try ControlOutput.poll(id: id, seconds: wait, launchTimeout: launch.launchTimeout)
                    }
                    report["approval"] = request
                    exit = ControlOutput.exitCode(for: request["state"]?.stringValue)
                }
            }
        }
        print(ControlOutput.json(.object(report)))
        if let exit { throw exit }
    }
}

struct SetupFinishCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "finish",
        abstract: "Close onboarding; LokalBot runs as a menu bar app from now on.")

    @OptionGroup var launch: AppLaunchOptions

    func run() throws {
        print(ControlOutput.json(try launch.request(.setupFinish)))
    }
}

struct SetupLaunchAtLoginCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "launch-at-login",
        abstract: "Turn starting LokalBot at login on or off.")

    @Argument(help: "on or off.")
    var state: String

    @OptionGroup var launch: AppLaunchOptions

    func run() throws {
        guard state == "on" || state == "off" else { throw ValidationError("Say on or off.") }
        print(ControlOutput.json(try launch.request(.launchAtLogin, params: ["enabled": .bool(state == "on")])))
    }
}

struct ModelsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "models",
        abstract: "Check, choose, and download LokalBot's local models.",
        discussion: """
            Downloads take minutes: start one, then poll status until
            meetingReady is true. Needs settings access.

              lokalbot-cli models preset recommended
              lokalbot-cli models status
            """,
        subcommands: [ModelsStatusCommand.self, ModelsPresetCommand.self, ModelsDownloadCommand.self, ModelsCancelCommand.self],
        defaultSubcommand: ModelsStatusCommand.self)
}

struct ModelsStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Readiness and download progress for each model role, and the preset suited to this Mac.")

    @OptionGroup var launch: AppLaunchOptions

    func run() throws {
        print(ControlOutput.json(try launch.request(.modelsStatus)))
    }
}

struct ModelsPresetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "preset",
        abstract: "Download and switch to a model preset: recommended or lightweight.",
        discussion: "The current models stay in use until the new ones are ready.")

    @Argument(help: "recommended or lightweight.")
    var preset: String

    @OptionGroup var launch: AppLaunchOptions

    func run() throws {
        guard AppControlProtocol.modelPresets.contains(preset) else {
            throw ValidationError("Choose a preset: \(AppControlProtocol.modelPresets.joined(separator: ", ")).")
        }
        print(ControlOutput.json(try launch.request(.modelsPreset, params: ["preset": .string(preset)])))
    }
}

struct ModelsDownloadCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "download",
        abstract: "Download the models the current selection needs.")

    @OptionGroup var launch: AppLaunchOptions

    func run() throws {
        print(ControlOutput.json(try launch.request(.modelsDownload)))
    }
}

struct ModelsCancelCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cancel",
        abstract: "Stop switching to a preset; the current models stay.")

    @OptionGroup var launch: AppLaunchOptions

    func run() throws {
        print(ControlOutput.json(try launch.request(.modelsCancel)))
    }
}

struct PermissionsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "permissions",
        abstract: "List macOS permissions and ask the person for one.",
        discussion: """
            The list shows each permission, whether it is granted, and which
            enabled features need it. request shows the macOS prompt, or
            System Settings with LokalBot's guidance; the person decides.
            Poll the list until it shows the grant.
            """,
        subcommands: [PermissionsListCommand.self, PermissionsRequestCommand.self],
        defaultSubcommand: PermissionsListCommand.self)
}

struct PermissionsListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List macOS permissions.")

    @OptionGroup var launch: AppLaunchOptions

    func run() throws {
        print(ControlOutput.json(try launch.request(.permissionsList)))
    }
}

struct PermissionsRequestCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "request",
        abstract: "Ask the person for a permission.")

    @Argument(help: ArgumentHelp(AppControlProtocol.permissionNames.joined(separator: ", ") + ".", valueName: "name"))
    var name: String

    @OptionGroup var launch: AppLaunchOptions

    func run() throws {
        guard AppControlProtocol.permissionNames.contains(name) else {
            throw ValidationError("Name a permission: \(AppControlProtocol.permissionNames.joined(separator: ", ")).")
        }
        print(ControlOutput.json(try launch.request(.permissionsRequest, params: ["name": .string(name)])))
    }
}

struct RestartCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restart",
        abstract: "Restart LokalBot, as macOS needs after Accessibility or Input Monitoring.",
        discussion: "Refused while LokalBot is recording. Waits up to 30 seconds for LokalBot to answer again.")

    @OptionGroup var launch: AppLaunchOptions

    func run() throws {
        _ = try launch.request(.restart)
        Thread.sleep(forTimeInterval: 2)
        let back = (try? AppControlClient().request(.hello, launch: false, launchTimeout: 30)) != nil
        print(ControlOutput.json(["restarted": .bool(back)]))
        if !back { throw ExitCode.failure }
    }
}

struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check whether LokalBot is ready, and list the next steps.",
        discussion: "Exits 1 while anything blocks a feature the person turned on.")

    @OptionGroup var launch: AppLaunchOptions

    func run() throws {
        var report: [String: JSONValue]
        do {
            report = try launch.request(.doctor).objectValue ?? [:]
        } catch let error as AppControlError where error.code == AppControlError.settingsAccessDisabled.code {
            report = [
                "ready": false,
                "checks": [["name": "settingsAccess", "ok": false, "detail": .string(error.message)]],
                "nextSteps": ["Run `lokalbot-cli setup start --wait 300` and ask the person to allow it in LokalBot."],
            ]
        }
        let onPath = Self.cliOnPath()
        var checks: [JSONValue] = []
        if case .array(let items)? = report["checks"] { checks = items }
        checks.append(["name": "cliOnPath", "ok": .bool(onPath), "detail": .string(onPath
            ? "lokalbot-cli is on PATH." : "lokalbot-cli is not on PATH. Settings → Agent CLI installs it in ~/.local/bin.")])
        report["checks"] = .array(checks)
        print(ControlOutput.json(.object(report)))
        if report["ready"] != .bool(true) { throw ExitCode.failure }
    }

    private static func cliOnPath() -> Bool {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return path.split(separator: ":").contains { directory in
            FileManager.default.isExecutableFile(atPath: "\(directory)/lokalbot-cli")
        }
    }
}
