import XCTest
@testable import LokalBot

final class AgentWorkspaceTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-workspace-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testArchiveUsesOnlySelectedBranchAndForkPreservesOriginal() throws {
        let file = root.appendingPathComponent("original.jsonl")
        try write([
            ["type": "session", "version": 3, "id": "session", "cwd": root.path],
            entry("u1", parent: nil, role: "user", text: "Question"),
            entry("a1", parent: "u1", role: "assistant", text: "Abandoned answer"),
            entry("a2", parent: "u1", role: "assistant", text: "Chosen answer"),
            entry("u2", parent: "a2", role: "user", text: "Later question"),
        ], to: file)
        let originalBytes = try Data(contentsOf: file)
        let saved = try XCTUnwrap(AgentSessionHistory.load(from: root).first)
        let transcript = try AgentConversationArchive.transcript(for: saved, directory: root)
        XCTAssertEqual(transcript.items.map(\.searchableText), ["Question", "Chosen answer", "Later question"])
        let fork = try AgentConversationArchive.fork(saved, through: transcript.items[1], matchingOccurrenceFromEnd: 0, directory: root)
        XCTAssertNotEqual(fork.fileURL, file)
        XCTAssertEqual(try Data(contentsOf: file), originalBytes)
        XCTAssertEqual(try AgentConversationArchive.transcript(for: fork, directory: root).items.map(\.searchableText), ["Question", "Chosen answer"])
        let records = try AgentConversationArchive.records(for: fork, directory: root)
        XCTAssertEqual(records.first?["parentSession"] as? String, file.path)
    }

    func testBranchChoosesTheCorrectRepeatedMessage() throws {
        let file = root.appendingPathComponent("repeated.jsonl")
        try write([
            ["type": "session", "version": 3, "id": "session", "cwd": root.path],
            entry("u1", parent: nil, role: "user", text: "Again"),
            entry("a1", parent: "u1", role: "assistant", text: "First"),
            entry("u2", parent: "a1", role: "user", text: "Again"),
        ], to: file)
        let saved = try XCTUnwrap(AgentSessionHistory.load(from: root).first)
        let fork = try AgentConversationArchive.fork(saved, through: .user(id: "local", text: "Again"), matchingOccurrenceFromEnd: 1, directory: root)
        XCTAssertEqual(try AgentConversationArchive.transcript(for: fork, directory: root).items.count, 1)
    }

    func testArchiveRejectsReplacedFileAndSymlink() throws {
        let file = root.appendingPathComponent("original.jsonl")
        let records: [[String: Any]] = [["type": "session", "id": "a", "cwd": root.path], entry("u", parent: nil, role: "user", text: "Hello")]
        try write(records, to: file)
        let saved = try XCTUnwrap(AgentSessionHistory.load(from: root).first)
        let other = root.appendingPathComponent("other.jsonl")
        try write(records, to: other)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
        XCTAssertThrowsError(try AgentConversationArchive.transcript(for: saved, directory: root))
    }

    func testAttachmentIsRereadAtSendAndDisplayKeepsContextOutOfUserBubble() throws {
        let file = root.appendingPathComponent("notes.md")
        try Data("Before".utf8).write(to: file)
        let source = AgentAttachment.file(file)
        let resolver = AgentContextResolver(root: root)
        XCTAssertEqual(try resolver.resolve(source).text, "Before")
        try Data("After".utf8).write(to: file)
        let prompt = try resolver.prompt("Summarize this", attachments: [source])
        XCTAssertTrue(prompt.contains("After"))
        XCTAssertFalse(prompt.contains("Before"))
        XCTAssertEqual(AgentContextResolver.displayPrompt(prompt), "Summarize this")
        XCTAssertEqual(AgentContextResolver.attachments(in: prompt), [source])
        let sessionFile = root.appendingPathComponent("attachments.jsonl")
        try write([["type": "session", "id": "attached", "cwd": root.path],
                   entry("u", parent: nil, role: "user", text: prompt)], to: sessionFile)
        let saved = try XCTUnwrap(AgentSessionHistory.load(from: root).first)
        let preview = try AgentConversationArchive.preview(for: saved, directory: root)
        XCTAssertEqual(preview.attachments[try XCTUnwrap(preview.folder.items.first).id], [source])
        try FileManager.default.removeItem(at: file)
        XCTAssertThrowsError(try resolver.prompt("Summarize this", attachments: [source]))
    }

    func testAttachmentsRejectBinaryAndOversizeWithoutSilentlyTruncating() throws {
        let file = root.appendingPathComponent("data.txt")
        try Data([0, 255, 20]).write(to: file)
        XCTAssertThrowsError(try AgentContextResolver(root: root).resolve(.file(file)))
        try Data(String(repeating: "x", count: 60_001).utf8).write(to: file)
        XCTAssertThrowsError(try AgentContextResolver(root: root).resolve(.file(file)))
    }

    func testForkCarriesRecordedToolResultsWithoutReplayingCalls() throws {
        let file = root.appendingPathComponent("tools.jsonl")
        try write([
            ["type": "session", "version": 3, "id": "tools", "cwd": root.path],
            entry("u", parent: nil, role: "user", text: "Read notes"),
            ["type": "message", "id": "a", "parentId": "u", "message": ["role": "assistant", "content": [
                ["type": "text", "text": "Reading notes"],
                ["type": "toolCall", "id": "call", "name": "read", "arguments": ["path": "notes.md"]],
            ]]],
            ["type": "message", "id": "t", "parentId": "a", "message": ["role": "toolResult", "toolCallId": "call", "content": "Notes"]],
            entry("later", parent: "t", role: "assistant", text: "Later answer"),
        ], to: file)
        let saved = try XCTUnwrap(AgentSessionHistory.load(from: root).first)
        let fork = try AgentConversationArchive.fork(saved, through: .assistant(id: "a", text: "Reading notes", isStreaming: false),
                                                    matchingOccurrenceFromEnd: 0, directory: root)
        let entries = try AgentConversationArchive.records(for: fork, directory: root)
        XCTAssertEqual(entries.last?["id"] as? String, "t")
        XCTAssertFalse(entries.contains { $0["id"] as? String == "later" })
    }

    func testRevokedScreenAccessBlocksAnAlreadyAttachedMoment() throws {
        let source = AgentAttachment(id: "moment:1", kind: .moment, title: "Saved", reference: "1")
        let gate = ScreenMemoryAccessGate(root: root)
        try gate.enable()
        gate.disable()
        XCTAssertThrowsError(try AgentContextResolver(root: root).prompt("Use this", attachments: [source])) { error in
            XCTAssertTrue(error is ScreenMemoryAccessError)
        }
    }

    func testTaskMetadataStoresReferencesAndQueuedDraftsWithoutSourceText() throws {
        let attachment = AgentAttachment.file(root.appendingPathComponent("notes.md"))
        var record = AgentTaskRecord(id: UUID(), title: "Pinned task", workspace: root)
        record.attachments = [attachment]
        record.queuedPrompts = [.init(text: "Follow up", attachments: [attachment])]
        record.isPinned = true; record.isArchived = true
        let store = AgentTaskStore(directory: root)
        try store.save([record])
        XCTAssertEqual(try store.load(), [record])
        let permissions = try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testActivityGroupingPreservesMessageOrderAndKeepsApprovalsOutOfTranscript() {
        let approval = AgentApprovalRequest(id: "approval", tool: "write", workspace: nil, path: nil, command: nil, content: "draft", edits: [], summary: nil, isTruncated: false)
        let items: [AgentTranscriptItem] = [
            .user(id: "u", text: "Question"),
            .tool(id: "t1", name: "read", argsJSON: "{}", output: "A", status: .succeeded),
            .tool(id: "t2", name: "read", argsJSON: "{}", output: "B", status: .succeeded),
            .approval(approval), .assistant(id: "a", text: "Answer", isStreaming: false),
        ]
        let groups = AgentTranscriptGroup.make(items)
        XCTAssertEqual(groups.map(\.id), ["u", "t1", "a"])
        XCTAssertEqual(groups[1].summary, "Read 2 files")
        XCTAssertEqual(groups[1].items.count, 2)
    }

    private func entry(_ id: String, parent: String?, role: String, text: String) -> [String: Any] {
        ["type": "message", "id": id, "parentId": parent as Any? ?? NSNull(), "message": ["role": role, "content": text]]
    }
    private func write(_ values: [[String: Any]], to file: URL) throws {
        var data = Data()
        for value in values { data.append(try JSONSerialization.data(withJSONObject: value)); data.append(0x0A) }
        try data.write(to: file)
    }
}
