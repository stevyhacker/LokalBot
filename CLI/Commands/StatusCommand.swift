import ArgumentParser
import Foundation

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show the running app's version, recording state, permissions, and agent access.",
        discussion: """
            Needs "Allow external agents to change LokalBot settings" in
            LokalBot → Settings → Privacy. Starts LokalBot in the background
            when it is not running unless --no-launch is given.
            """)

    @OptionGroup var launch: AppLaunchOptions

    func run() throws {
        print(ControlOutput.json(try launch.request(.status)))
    }
}
