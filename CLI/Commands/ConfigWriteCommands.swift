import ArgumentParser
import Foundation

struct ConfigSetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Change settings in the running app.",
        discussion: """
            Pass key=value pairs; values use the tokens from describe. Lists
            take commas or JSON, and structured values take JSON as get prints
            it. All pairs apply or none do. Preferences, and changes that
            narrow what LokalBot captures or sends, apply right away.
            Turning on capture, a data source, or sharing (tier consent)
            sends the whole request to the person in LokalBot and returns
            needs_approval with a request id (exit 3). --wait follows it:
            exit 0 approved, 4 declined, 5 expired.

              lokalbot-cli config set noteTemplate=lecture summaryLanguage=en
              lokalbot-cli config set trackingEnabled=false --dry-run
              lokalbot-cli config set calendarDetectionEnabled=true --wait 120
            """)

    @Argument(help: "key=value pairs.")
    var assignments: [String]

    @Flag(name: .long, help: "Report what would change without changing anything.")
    var dryRun: Bool = false

    @OptionGroup var approval: ApprovalWaitOptions

    @OptionGroup var launch: AppLaunchOptions

    func run() throws {
        guard !assignments.isEmpty else { throw ValidationError("Name at least one key=value pair.") }
        var changes: [String: JSONValue] = [:]
        for assignment in assignments {
            guard let separator = assignment.firstIndex(of: "="), separator != assignment.startIndex else {
                throw ValidationError("\(assignment) is not key=value.")
            }
            let key = String(assignment[..<separator])
            guard changes[key] == nil else { throw ValidationError("\(key) is given twice.") }
            let spec = try ControlOutput.requireSpec(key)
            changes[key] = try spec.parse(String(assignment[assignment.index(after: separator)...]))
        }
        let request = SettingsChangeRequest(changes: changes, dryRun: dryRun)
        try ControlOutput.sendForApproval(.settingsSet, params: request.params, launch: launch, wait: approval.wait)
    }
}

struct ConfigResetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reset",
        abstract: "Put settings back to their defaults.",
        discussion: "Follows the same rules as set: a reset that would widen capture or sharing waits for the person.")

    @Argument(help: "One or more setting keys.")
    var keys: [String]

    @Flag(name: .long, help: "Report what would change without changing anything.")
    var dryRun: Bool = false

    @OptionGroup var approval: ApprovalWaitOptions

    @OptionGroup var launch: AppLaunchOptions

    func run() throws {
        guard !keys.isEmpty else { throw ValidationError("Name at least one setting key.") }
        for key in keys { _ = try ControlOutput.requireSpec(key) }
        guard Set(keys).count == keys.count else { throw ValidationError("A key is given twice.") }
        let request = SettingsChangeRequest(reset: keys, dryRun: dryRun)
        try ControlOutput.sendForApproval(.settingsSet, params: request.params, launch: launch, wait: approval.wait)
    }
}

struct ConfigExportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Print settings as a JSON object that import accepts.",
        discussion: "URLs are shown without user names, passwords, or query strings; importing them back keeps those parts.")

    @Flag(name: .long, help: "Only settings that differ from their defaults.")
    var changed: Bool = false

    @OptionGroup var launch: AppLaunchOptions

    func run() throws {
        guard case .array(let entries) = try launch.request(.settingsList) else {
            throw AppControlError.invalidRequest("LokalBot returned an unexpected settings list.")
        }
        var object: [String: JSONValue] = [:]
        for entry in entries {
            guard let key = entry["key"]?.stringValue, entry["tier"]?.stringValue != SettingTier.readOnly.rawValue,
                  !changed || entry["changed"] == JSONValue.bool(true),
                  let value = entry["value"], value != .null else { continue }
            object[key] = value
        }
        print(ControlOutput.json(.object(object)))
    }
}

struct ConfigImportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Apply a JSON object of settings, as export prints it.",
        discussion: """
            Keys whose values already match are left alone. Follows the same
            rules as set, all or nothing. Read the file with - for stdin.

              lokalbot-cli config export --changed > settings.json
              lokalbot-cli config import settings.json --dry-run
            """)

    @Argument(help: "A JSON file, or - for stdin.")
    var file: String

    @Flag(name: .long, help: "Report what would change without changing anything.")
    var dryRun: Bool = false

    @OptionGroup var approval: ApprovalWaitOptions

    @OptionGroup var launch: AppLaunchOptions

    func run() throws {
        let data = file == "-"
            ? FileHandle.standardInput.readDataToEndOfFile()
            : try Data(contentsOf: URL(fileURLWithPath: (file as NSString).expandingTildeInPath))
        guard let object = (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue, !object.isEmpty else {
            throw ValidationError("\(file) must hold a JSON object of setting keys and values.")
        }
        for key in object.keys { _ = try ControlOutput.requireSpec(key) }
        let request = SettingsChangeRequest(changes: object, dryRun: dryRun)
        try ControlOutput.sendForApproval(.settingsSet, params: request.params, launch: launch, wait: approval.wait)
    }
}
