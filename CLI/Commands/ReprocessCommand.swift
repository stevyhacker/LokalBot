import ArgumentParser
import Foundation

enum ReprocessExit {
    static let stillRunning = ExitCode(3)
}

struct ReprocessCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reprocess",
        abstract: "Summarize a meeting again, or transcribe it again first, in LokalBot.",
        discussion: """
            Does what Reprocess does in the meeting's toolbar menu. By default
            LokalBot writes new notes from the saved transcript with the notes
            model, template, and language chosen in Settings, which may be a
            cloud model the person approved. The previous notes are kept as
            summary.previous.md. --transcribe runs speech recognition on the
            recording again first, on this Mac; add --no-summary to stop there.

            Needs "Allow external agents to change LokalBot settings". The work
            runs in LokalBot, which this command starts in the background when
            it isn't running. --wait follows it: exit 0 finished, 1 failed,
            3 still running or waiting for models when the wait ends.

              lokalbot-cli reprocess latest
              lokalbot-cli reprocess fb709013 --wait 600
              lokalbot-cli reprocess fb709013 --transcribe --no-summary
            """)

    @Argument(help: "Meeting ID from `list`, or 'latest' for the most recent.")
    var id: String

    @Flag(name: .long, help: "Transcribe the recording again before summarizing. Speech recognition runs on this Mac.")
    var transcribe: Bool = false

    @Flag(name: .long, help: "With --transcribe, only transcribe and keep the current notes.")
    var noSummary: Bool = false

    @Option(name: .long, help: ArgumentHelp(
        "Seconds to follow the work until it finishes (at most 3600).",
        valueName: "seconds"))
    var wait: Double?

    @OptionGroup var launch: AppLaunchOptions

    func validate() throws {
        if noSummary && !transcribe {
            throw ValidationError("--no-summary only applies with --transcribe.")
        }
        if let wait, wait <= 0 {
            throw ValidationError("--wait must be positive.")
        }
    }

    func run() throws {
        var result = try launch.request(.meetingsReprocess, params: [
            "id": .string(id),
            "transcribe": .bool(transcribe),
            "summarize": .bool(!noSummary),
        ])
        if let wait {
            ControlOutput.standardError("Following the work in LokalBot…")
            result = try Self.follow(
                id: result["id"]?.stringValue ?? id, seconds: wait, launchTimeout: launch.launchTimeout)
        }
        print(ControlOutput.json(result))
        guard wait != nil else { return }
        if let exit = Self.exitCode(for: result["state"]?.stringValue) { throw exit }
    }

    static func follow(id: String, seconds: Double, launchTimeout: Double) throws -> JSONValue {
        let deadline = Date().addingTimeInterval(min(seconds, 3600))
        var status: JSONValue
        repeat {
            Thread.sleep(forTimeInterval: 2)
            status = try AppControlClient().request(
                .meetingsProcessing, params: ["id": .string(id)], launch: false, launchTimeout: launchTimeout)
        } while !isSettled(status["state"]?.stringValue) && Date() < deadline
        return status
    }

    static func isSettled(_ state: String?) -> Bool {
        ["idle", "failed", "waitingForModels"].contains(state ?? "idle")
    }

    static func exitCode(for state: String?) -> ExitCode? {
        switch state {
        case "idle", nil:
            return nil
        case "failed":
            return .failure
        case "waitingForModels":
            ControlOutput.standardError("LokalBot is waiting for its models; download them in Settings → Models to finish.")
            return ReprocessExit.stillRunning
        default:
            ControlOutput.standardError("Still running in LokalBot. Check again with a longer --wait, or in the app.")
            return ReprocessExit.stillRunning
        }
    }
}
