import ArgumentParser
import Foundation

struct OpenCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open",
        abstract: "Open LokalBot's Settings, optionally at one setting.",
        discussion: """
            For what only the person can do in the app: macOS permissions,
            sign-in, or a change they want to make themselves.

              lokalbot-cli open settings
              lokalbot-cli open settings dictationShortcut
            """)

    @Argument(help: "What to open. Only settings is supported.")
    var target: String

    @Argument(help: "Optional setting key to show.")
    var key: String?

    @OptionGroup var launch: AppLaunchOptions

    func run() throws {
        guard target == "settings" else { throw ValidationError("open supports only `settings`.") }
        var params: [String: JSONValue] = ["target": "settings"]
        if let key {
            _ = try ControlOutput.requireSpec(key)
            params["key"] = .string(key)
        }
        print(ControlOutput.json(try launch.request(.open, params: params)))
    }
}
