import ArgumentParser
import Foundation

struct PathCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "path",
        abstract: "Print the on-disk path for a meeting or the library root.",
        discussion: """
            With no argument, prints the library root. With a meeting ID
            (from `list` or `latest`), prints that meeting's folder so a
            user can `cd $(lokalbot-cli path latest)`.
            """
    )

    @Argument(help: "Optional meeting ID. Omit to print the library root.")
    var id: String?

    func run() async throws {
        try AgentAccessGate().requireCommandAccess()
        guard let id else {
            print(SessionLookup.storageRootURL.path(percentEncoded: false))
            return
        }
        guard let meeting = try SessionLookup.find(id: id) else {
            throw ValidationError("No meeting with id '\(id)'.")
        }
        print(SessionLookup.folderURL(for: meeting).path(percentEncoded: false))
    }
}
