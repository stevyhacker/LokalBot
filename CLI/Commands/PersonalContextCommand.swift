import ArgumentParser
import Foundation

struct PersonalContextCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "personal-context",
        abstract: "Show what the user shared about themselves that is relevant to a task.",
        discussion: """
            Returns the facts, preferences, goals, and principles the user
            marked as shared in LokalBot → Settings → Personal Context,
            most relevant to --task first. Needs the separate personal-context
            permission in Settings → Privacy. JSON by default.
            """
    )

    @Option(name: .long, help: "What you are helping with, in a sentence.")
    var task: String

    @Option(name: .long, help: "Only this kind: fact, preference, goal, or principle. Repeatable.")
    var kind: [String] = []

    @Option(name: .long, help: "Maximum items (1–\(PersonalContextTool.maximumItems)).")
    var limit: Int = PersonalContextTool.defaultItems

    @Flag(name: .long, help: "Plain text instead of JSON.")
    var table: Bool = false

    func run() async throws {
        let result = PersonalContextTool.report(
            task: task, kinds: kind.isEmpty ? nil : kind, maxItems: limit,
            gate: PersonalContextAccessGate())
        switch result {
        case .success(let report):
            if table {
                if report.items.isEmpty { print("Nothing shared matches. Items not listed are unknown, not false.") }
                for item in report.items {
                    print("\(item.kind)\t\(item.asOf)\t\(item.text)")
                }
            } else {
                print(PersonalContextTool.json(report))
            }
        case .failure(.invalid(let message)):
            throw ValidationError(message)
        case .failure(let failure):
            throw failure
        }
    }
}
