import ArgumentParser
import Foundation

struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Inspect and change LokalBot settings.",
        discussion: """
            schema, describe, and search read the built-in settings list and
            need no permission. list, get, set, reset, export, and import use
            the running app and need "Allow external agents to change LokalBot
            settings" in LokalBot → Settings → Privacy. They start LokalBot in
            the background when it is not running; pass --no-launch to fail
            instead. Values use the tokens shown by describe. JSON by default.
            Changes that widen capture or sharing wait for the person's
            approval in LokalBot; request reports the answer.
            """,
        subcommands: [
            ConfigSchemaCommand.self,
            ConfigDescribeCommand.self,
            ConfigSearchCommand.self,
            ConfigListCommand.self,
            ConfigGetCommand.self,
            ConfigSetCommand.self,
            ConfigResetCommand.self,
            ConfigExportCommand.self,
            ConfigImportCommand.self,
            ConfigRequestCommand.self,
        ]
    )
}

/// How commands that need the running app reach it.
struct AppLaunchOptions: ParsableArguments {
    @Flag(name: .long, help: "Fail instead of starting LokalBot when it is not running.")
    var noLaunch: Bool = false

    @Option(name: .long, help: "Seconds to wait for LokalBot to start and answer.")
    var launchTimeout: Double = 30

    func request(
        _ method: AppControlProtocol.Method,
        params: [String: JSONValue]? = nil
    ) throws -> JSONValue {
        guard launchTimeout > 0 else { throw ValidationError("--launch-timeout must be positive.") }
        return try AppControlClient().request(
            method, params: params, launch: !noLaunch, launchTimeout: launchTimeout)
    }
}

enum ControlOutput {
    static func json(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? String(data: encoder.encode(value), encoding: .utf8)) ?? "null"
    }

    /// A value on one line: strings bare, everything else as compact JSON.
    static func plain(_ value: JSONValue?) -> String {
        guard let value else { return "" }
        if case .string(let text) = value { return text }
        if case .null = value { return "—" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? String(data: encoder.encode(value), encoding: .utf8)) ?? ""
    }

    static func requireSpec(_ key: String) throws -> SettingSpec {
        if let spec = SettingRegistry.spec(for: key) { return spec }
        let suggestions = SettingRegistry.search(key).prefix(5).map(\.key)
        let hint = suggestions.isEmpty
            ? "Run `lokalbot-cli config search <words>` to find one."
            : "Did you mean: \(suggestions.joined(separator: ", "))?"
        throw ValidationError("No setting is named \(key). \(hint)")
    }
}

struct ConfigSchemaCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "schema",
        abstract: "Print a JSON Schema of every setting (no values).")

    func run() throws {
        print(ControlOutput.json(SettingRegistry.jsonSchema))
    }
}

struct ConfigDescribeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "describe",
        abstract: "Describe one setting: type, allowed values, range, category, and tier.",
        discussion: """
            tier is preference (changes nothing about what is captured or
            sent), consent (widening it needs approval in LokalBot), or
            readOnly (never changed from the terminal).
            """)

    @Argument(help: "Setting key, e.g. autoRecordMode.")
    var key: String

    func run() throws {
        print(ControlOutput.json(try ControlOutput.requireSpec(key).descriptionJSON))
    }
}

struct ConfigSearchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Find settings by words in their key, title, or description.")

    @Argument(help: "Words to match, e.g. dark mode.")
    var words: [String]

    @Flag(name: .long, help: "Plain-text table instead of JSON.")
    var table: Bool = false

    func run() throws {
        let matches = SettingRegistry.search(words.joined(separator: " "))
        if table {
            guard !matches.isEmpty else { print("(no settings)"); return }
            print(SessionFormatter.renderTable(
                header: ["Key", "Title", "Category", "Tier"],
                rows: matches.map { [$0.key, $0.title, $0.category.rawValue, $0.tier.rawValue] }))
            return
        }
        print(ControlOutput.json(.array(matches.map { spec in
            [
                "key": .string(spec.key),
                "title": .string(spec.title),
                "category": .string(spec.category.rawValue),
                "tier": .string(spec.tier.rawValue),
                "summary": .string(spec.summary),
            ]
        })))
    }
}

struct ConfigListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List current values from the running app.")

    @Option(name: .long, help: "Only one category: \(SettingCategory.allCases.map(\.rawValue).joined(separator: ", ")).")
    var category: String?

    @Flag(name: .long, help: "Only settings that differ from their defaults.")
    var changed: Bool = false

    @Flag(name: .long, help: "Plain-text table instead of JSON.")
    var table: Bool = false

    @OptionGroup var launch: AppLaunchOptions

    func run() throws {
        if let category, SettingCategory(rawValue: category) == nil {
            throw ValidationError("Unknown category \(category).")
        }
        var params: [String: JSONValue] = [:]
        if let category { params["category"] = .string(category) }
        guard case .array(var entries) = try launch.request(.settingsList, params: params) else {
            throw AppControlError.invalidRequest("LokalBot returned an unexpected settings list.")
        }
        if changed { entries = entries.filter { $0["changed"] == JSONValue.bool(true) } }
        guard table else {
            print(ControlOutput.json(.array(entries)))
            return
        }
        guard !entries.isEmpty else { print("(no settings)"); return }
        print(SessionFormatter.renderTable(
            header: ["Key", "Value", "Default", "Tier"],
            rows: entries.map { entry in
                [ControlOutput.plain(entry["key"]),
                 String(ControlOutput.plain(entry["value"]).prefix(60)),
                 String(ControlOutput.plain(entry["default"]).prefix(40)),
                 ControlOutput.plain(entry["tier"])]
            }))
    }
}

struct ConfigGetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Read settings from the running app.",
        discussion: """
            One key prints that setting's entry; several keys print an array.
            --value prints only the value, for scripts.
            """)

    @Argument(help: "One or more setting keys.")
    var keys: [String]

    @Flag(name: .long, help: "Print only the value of each key, one per line.")
    var value: Bool = false

    @OptionGroup var launch: AppLaunchOptions

    func run() throws {
        guard !keys.isEmpty else { throw ValidationError("Name at least one setting key.") }
        for key in keys { _ = try ControlOutput.requireSpec(key) }
        let result = try launch.request(.settingsGet, params: ["keys": .array(keys.map(JSONValue.string))])
        guard case .array(let entries) = result else {
            throw AppControlError.invalidRequest("LokalBot returned an unexpected settings reply.")
        }
        if value {
            print(entries.map { ControlOutput.plain($0["value"]) }.joined(separator: "\n"))
        } else if entries.count == 1, let entry = entries.first {
            print(ControlOutput.json(entry))
        } else {
            print(ControlOutput.json(.array(entries)))
        }
    }
}
