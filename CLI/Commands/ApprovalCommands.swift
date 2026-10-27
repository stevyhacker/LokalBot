import ArgumentParser
import Foundation

/// Exit codes for requests that need the person, so a script can tell a
/// request still waiting from one they declined or nobody answered.
enum ApprovalExit {
    static let waiting = ExitCode(3)
    static let denied = ExitCode(4)
    static let expired = ExitCode(5)
}

struct ApprovalWaitOptions: ParsableArguments {
    @Option(name: .long, help: ArgumentHelp(
        "Seconds to wait for the person to answer in LokalBot (at most 300).",
        valueName: "seconds"))
    var wait: Double?
}

extension ControlOutput {
    /// Sends a request that may need the person and prints the reply. A
    /// request left waiting prints as JSON and exits 3, or, with --wait, is
    /// followed until the person answers: 0 approved, 4 denied, 5 expired.
    static func sendForApproval(
        _ method: AppControlProtocol.Method,
        params: [String: JSONValue],
        launch: AppLaunchOptions,
        wait: Double?
    ) throws {
        do {
            print(json(try launch.request(method, params: params)))
        } catch let error as AppControlError where error.code == "needs_approval" {
            guard let id = error.details?["id"]?.stringValue else { throw error }
            guard let wait, wait > 0 else {
                print(json([
                    "error": .string(error.code),
                    "message": .string(error.message),
                    "details": error.details ?? .null,
                ]))
                throw ApprovalExit.waiting
            }
            standardError("Waiting for the person to answer in LokalBot…")
            try waitForAnswer(id: id, seconds: wait, launchTimeout: launch.launchTimeout)
        } catch let error as AppControlError where error.details != nil {
            print(json([
                "error": .string(error.code),
                "message": .string(error.message),
                "details": error.details ?? .null,
            ]))
            throw ExitCode.failure
        }
    }

    /// Polls the running app until the request is answered or `seconds` pass.
    /// Never starts LokalBot: a request lives only in the copy that took it.
    static func waitForAnswer(id: String, seconds: Double, launchTimeout: Double) throws {
        try report(poll(id: id, seconds: seconds, launchTimeout: launchTimeout))
    }

    static func poll(id: String, seconds: Double, launchTimeout: Double) throws -> JSONValue {
        let deadline = Date().addingTimeInterval(min(seconds, 300))
        var request: JSONValue
        repeat {
            request = try AppControlClient().request(
                .settingsRequest, params: ["id": .string(id)], launch: false, launchTimeout: launchTimeout)
            guard request["state"]?.stringValue == SettingsRequestState.pending.rawValue else { break }
            Thread.sleep(forTimeInterval: 1)
        } while Date() < deadline
        return request
    }

    /// Prints a request and exits with the code its state maps to.
    static func report(_ request: JSONValue) throws {
        print(json(request))
        if let exit = exitCode(for: request["state"]?.stringValue) { throw exit }
    }

    /// Nil for approved; otherwise the exit code, with the reason on stderr.
    static func exitCode(for state: String?) -> ExitCode? {
        switch SettingsRequestState(rawValue: state ?? "") {
        case .approved:
            return nil
        case .denied:
            standardError(AppControlError.denied.errorDescription ?? "")
            return ApprovalExit.denied
        case .expired:
            standardError(AppControlError.expired.errorDescription ?? "")
            return ApprovalExit.expired
        case .pending, nil:
            standardError("[needs_approval] Still waiting for the person in LokalBot.")
            return ApprovalExit.waiting
        }
    }

    static func standardError(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

struct ConfigRequestCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "request",
        abstract: "Show whether the person answered a request that needed approval.",
        discussion: """
            Takes the id from a needs_approval reply. Exits 0 when approved,
            3 while waiting, 4 when the person declined, and 5 when nobody
            answered in time. LokalBot forgets answers after 30 minutes.

              lokalbot-cli config request 1F0C… --wait 120
            """)

    @Argument(help: "The request id from a needs_approval reply.")
    var id: String

    @OptionGroup var approval: ApprovalWaitOptions

    @Option(name: .long, help: "Seconds to wait for LokalBot to answer.")
    var launchTimeout: Double = 30

    func run() throws {
        if let wait = approval.wait, wait > 0 {
            try ControlOutput.waitForAnswer(id: id, seconds: wait, launchTimeout: launchTimeout)
        } else {
            try ControlOutput.report(AppControlClient().request(
                .settingsRequest, params: ["id": .string(id)], launch: false, launchTimeout: launchTimeout))
        }
    }
}

struct SecretCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "secret",
        abstract: "Save or remove API keys in LokalBot's Keychain. Keys are never read back.",
        discussion: """
            Needs "Allow external agents to change LokalBot settings". Setting
            a key always waits for the person's approval in LokalBot, because
            a key decides whose account receives what LokalBot sends.
            Removing one applies right away.
            """,
        subcommands: [SecretListCommand.self, SecretSetCommand.self, SecretClearCommand.self])
}

struct SecretListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the API keys and whether each is saved.")

    @OptionGroup var launch: AppLaunchOptions

    func run() throws {
        print(ControlOutput.json(try launch.request(.secretList)))
    }
}

struct SecretSetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Save an API key, after the person approves it in LokalBot.",
        discussion: """
            Reads the key from standard input, so it stays out of shell
            history and process lists. The approval card shows only its last
            four characters.

              printf %s "$KEY" | lokalbot-cli secret set openai-compatible --wait 120
            """)

    @Argument(help: ArgumentHelp(
        "Which key: " + AppSecret.allCases.map(\.rawValue).joined(separator: ", ") + ".",
        valueName: "name"))
    var name: String

    @OptionGroup var approval: ApprovalWaitOptions

    @OptionGroup var launch: AppLaunchOptions

    func run() throws {
        guard AppSecret(rawValue: name) != nil else { throw ValidationError(AppControlError.unknownSecret(name).message) }
        guard isatty(FileHandle.standardInput.fileDescriptor) == 0 else {
            throw ValidationError("Pipe the key on standard input, for example: printf %s \"$KEY\" | lokalbot-cli secret set \(name)")
        }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 4_096, !value.contains(where: \.isNewline) else {
            throw ValidationError("Standard input must hold the key on one line.")
        }
        try ControlOutput.sendForApproval(
            .secretSet, params: ["name": .string(name), "value": .string(value)],
            launch: launch, wait: approval.wait)
    }
}

struct SecretClearCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear",
        abstract: "Remove a saved API key.")

    @Argument(help: ArgumentHelp("Which key.", valueName: "name"))
    var name: String

    @OptionGroup var launch: AppLaunchOptions

    func run() throws {
        guard AppSecret(rawValue: name) != nil else { throw ValidationError(AppControlError.unknownSecret(name).message) }
        print(ControlOutput.json(try launch.request(.secretClear, params: ["name": .string(name)])))
    }
}
