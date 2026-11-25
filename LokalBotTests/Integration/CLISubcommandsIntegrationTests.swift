import XCTest
@testable import LokalBot

final class CLISubcommandsIntegrationTests: XCTestCase {
    private var root: URL!
    private let meetingA = UUID(uuidString: "AAAAAAAA-1111-4222-8333-444444444444")!
    private let meetingB = UUID(uuidString: "BBBBBBBB-2222-4333-8444-555555555555")!

    private var helperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/lokalbot-cli")
    }

    override func setUpWithError() throws {
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            XCTFail("embedded lokalbot-cli missing at \(helperURL.path)")
            throw NSError(domain: "CLISubcommandsIntegrationTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "embedded lokalbot-cli missing"])
        }
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-subcommands-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let recentStart = Date().addingTimeInterval(-3_600)
        let olderStart = Date().addingTimeInterval(-86_400)
        try MeetingFixture.write([
            .init(
                id: meetingA,
                title: "Cache architecture review",
                startedAt: recentStart,
                summary: "## TL;DR\nWe chose Redis for the caching layer.",
                transcriptLines: [
                    "Let us finalize the caching layer.",
                    "Redis wins because of pub sub.",
                ]),
            .init(
                id: meetingB,
                title: "Weekly product sync",
                startedAt: olderStart,
                summary: "## TL;DR\nReviewed onboarding funnel.",
                transcriptLines: ["Onboarding completion improved this week."]),
        ], under: root)

        let storage = StorageManager(rootURL: root)
        let meetings = storage.loadMeetings()
        let recent = try XCTUnwrap(meetings.first { $0.id == meetingA })
        var stamped = recent
        let maya = try XCTUnwrap(CalendarParticipantIdentity(
            id: "cal:maya",
            name: "Maya Chen",
            emailAddress: "maya@example.com"))
        stamped.calendarParticipantIdentities = [maya]
        try storage.saveMeta(stamped)
        let folder = stamped.folderURL(in: storage)
        let outcomes = MeetingOutcomes(
            actionItems: [
                MeetingOutcomes.ActionItem(
                    id: "act-redis-1",
                    text: "Ship Redis connection pooling",
                    owner: "Maya Chen",
                    due: "Friday",
                    isForUser: false,
                    citations: []),
                MeetingOutcomes.ActionItem(
                    id: "act-redis-2",
                    text: "Benchmark cache hit rate",
                    owner: "Me",
                    due: "tomorrow",
                    isForUser: true,
                    citations: []),
            ],
            decisions: ["Adopt Redis for session cache"])
        try outcomes.write(to: folder)
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    private struct RunResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private func runCLI(_ arguments: [String]) throws -> RunResult {
        let process = Process()
        process.executableURL = helperURL
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["LOKALBOT_STORAGE_ROOT"] = root.path
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return RunResult(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self))
    }

    private func snapshotFiles(under directory: URL) throws -> [String: (Int, Date)] {
        var result: [String: (Int, Date)] = [:]
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: keys))
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }
            let relative = file.path.replacingOccurrences(of: directory.path, with: "")
            result[relative] = (values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
        return result
    }

    func testConsentGateBlocksLibraryCommandsUntilEnabled() throws {
        for command in [
            ["list"],
            ["get", "latest"],
            ["search", "redis"],
            ["actions"],
            ["people"],
            ["path"],
        ] {
            let result = try runCLI(command)
            XCTAssertNotEqual(result.status, 0, "\(command.joined(separator: " ")) must refuse without consent")
            XCTAssertFalse(result.stdout.contains("Cache architecture review"), command.joined(separator: " "))
        }

        let brief = try runCLI(["brief"])
        XCTAssertEqual(brief.status, 0)
        XCTAssertFalse(brief.stdout.contains("Cache architecture review"))
        XCTAssertFalse(brief.stdout.contains("Redis"))
    }

    func testLibrarySubcommandsReturnExpectedDataWithoutMutatingDisk() throws {
        try AgentAccessGate(root: root).enable()
        let before = try snapshotFiles(under: root)

        let rootPath = try runCLI(["path"])
        XCTAssertEqual(rootPath.status, 0)
        XCTAssertEqual(
            URL(fileURLWithPath: rootPath.stdout.trimmingCharacters(in: .whitespacesAndNewlines)).standardizedFileURL.path,
            root.standardizedFileURL.path)

        let latestPath = try runCLI(["path", "latest"])
        XCTAssertEqual(latestPath.status, 0)
        XCTAssertTrue(latestPath.stdout.contains("aaaaaaaa-fixture"))

        let list = try runCLI(["list"])
        XCTAssertEqual(list.status, 0)
        let listItems = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(list.stdout.utf8)) as? [[String: Any]])
        XCTAssertEqual(listItems.count, 2)
        XCTAssertEqual(listItems.first?["title"] as? String, "Cache architecture review")

        let filtered = try runCLI(["list", "--query", "cache", "--limit", "1", "--include", "summary"])
        XCTAssertEqual(filtered.status, 0)
        let filteredItems = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(filtered.stdout.utf8)) as? [[String: Any]])
        XCTAssertEqual(filteredItems.count, 1)
        XCTAssertTrue((filteredItems.first?["summary"] as? String)?.contains("Redis") == true)

        let listTable = try runCLI(["list", "--table"])
        XCTAssertEqual(listTable.status, 0)
        XCTAssertTrue(listTable.stdout.contains("Cache architecture review"))

        let getJSON = try runCLI(["get", "latest", "--format", "json"])
        XCTAssertEqual(getJSON.status, 0)
        let meetingObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(getJSON.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(meetingObject["title"] as? String, "Cache architecture review")
        XCTAssertTrue((meetingObject["summary"] as? String)?.contains("Redis") == true)

        let getMD = try runCLI(["get", "aaaaaaaa", "--include", "summary,transcript", "--format", "md"])
        XCTAssertEqual(getMD.status, 0)
        XCTAssertTrue(getMD.stdout.contains("Redis wins because of pub sub."))

        let search = try runCLI(["search", "redis"])
        XCTAssertEqual(search.status, 0)
        let hits = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(search.stdout.utf8)) as? [[String: Any]])
        XCTAssertFalse(hits.isEmpty)
        XCTAssertTrue(search.stdout.lowercased().contains("redis"))

        let actions = try runCLI(["actions", "--status", "all"])
        XCTAssertEqual(actions.status, 0)
        let actionItems = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(actions.stdout.utf8)) as? [[String: Any]])
        XCTAssertEqual(actionItems.count, 2)
        XCTAssertTrue(actions.stdout.contains("Benchmark cache hit rate"))

        let people = try runCLI(["people"])
        XCTAssertEqual(people.status, 0)
        XCTAssertTrue(people.stdout.contains("Maya Chen"))
        XCTAssertFalse(people.stdout.contains("maya@example.com"))

        let personDetail = try runCLI(["people", "Maya Chen"])
        XCTAssertEqual(personDetail.status, 0)
        XCTAssertTrue(personDetail.stdout.contains("Ship Redis connection pooling"))
        XCTAssertFalse(personDetail.stdout.contains("maya@example.com"))

        let brief = try runCLI(["brief"])
        XCTAssertEqual(brief.status, 0)
        XCTAssertTrue(brief.stdout.contains("Benchmark cache hit rate"))

        let after = try snapshotFiles(under: root)
        XCTAssertEqual(before.keys.sorted(), after.keys.sorted())
        for (path, beforeMeta) in before {
            let afterMeta = try XCTUnwrap(after[path])
            XCTAssertEqual(beforeMeta.0, afterMeta.0, path)
            XCTAssertEqual(beforeMeta.1, afterMeta.1, path)
        }
    }

    func testInvalidArgumentsExitNonZero() throws {
        try AgentAccessGate(root: root).enable()

        XCTAssertNotEqual(try runCLI(["list", "--include", "transcript"]).status, 0)
        XCTAssertNotEqual(try runCLI(["list", "--since", "2026-02-30"]).status, 0)
        XCTAssertNotEqual(try runCLI(["get", "deadbeef"]).status, 0)
        XCTAssertNotEqual(try runCLI(["get", "latest", "--format", "xml"]).status, 0)
        XCTAssertNotEqual(try runCLI(["search", "   "]).status, 0)
        XCTAssertNotEqual(try runCLI(["actions", "--status", "invalid"]).status, 0)
        XCTAssertNotEqual(try runCLI(["people", "Nobody Matching"]).status, 0)
        XCTAssertNotEqual(try runCLI(["not-a-subcommand"]).status, 0)
    }
}
