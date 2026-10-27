import CryptoKit
import XCTest
@testable import LokalBot

/// Phase 2 of the personal world model: the Personal context grant, the
/// shared projection the app keeps in step, and `get_personal_context`.
@MainActor
final class PersonalContextAccessTests: XCTestCase {
    private var root: URL!
    private let key = SymmetricKey(data: Data(repeating: 0x7A, count: 32))
    private var clock = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersonalContextAccessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private struct Fixture {
        let personal: PersonalModelController
        let access: PersonalContextAccessManager
        let gate: PersonalContextAccessGate
    }

    private func makeFixture() -> Fixture {
        let store = PersonalModelStore(root: root, encryptionKey: { [key] in key })
        let personal = PersonalModelController(store: store, now: { [unowned self] in clock })
        let gate = PersonalContextAccessGate(root: root)
        let access = PersonalContextAccessManager(
            gate: gate, claims: { personal.readableClaims() }, now: { [unowned self] in clock })
        personal.onChange = { access.refresh($0) }
        return Fixture(personal: personal, access: access, gate: gate)
    }

    private func sharedTexts(_ gate: PersonalContextAccessGate) -> [String]? {
        gate.readProjection()?.claims.map(\.text).sorted()
    }

    func testPhaseOneClaimsDecodeAsLokalBotOnly() throws {
        let json = """
            {"version":1,"claims":[{"id":"6F9619FF-8B86-4D11-B42D-00C04FC964FF","kind":"principle",
            "text":"No relocation","origin":{"added":{}},"alwaysUse":false,
            "createdAt":"2026-10-14T10:00:00Z","updatedAt":"2026-10-14T10:00:00Z"}]}
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let model = try decoder.decode(PersonalModel.self, from: Data(json.utf8))
        XCTAssertEqual(model.claims.first?.sharing, .lokalBotOnly)
        XCTAssertEqual(model.claims.first?.kind, .principle)
    }

    func testProjectionHoldsOnlySharedClaimsAndFollowsEveryEdit() throws {
        let fixture = makeFixture()
        let principle = try fixture.personal.remember(
            "I don't take work that requires relocating my family", kind: .principle, origin: .added).get()
        let privateFact = try fixture.personal.remember("My salary is confidential", origin: .added).get()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.gate.projectionURL.path))

        fixture.access.setEnabled(true)
        XCTAssertEqual(sharedTexts(fixture.gate), [])
        XCTAssertEqual(fixture.access.sharedCount, 0)

        _ = fixture.personal.update(principle.id, sharing: .agents)
        XCTAssertEqual(sharedTexts(fixture.gate), ["I don't take work that requires relocating my family"])
        XCTAssertEqual(fixture.access.sharedCount, 1)
        let permissions = try FileManager.default.attributesOfItem(
            atPath: fixture.gate.projectionURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)

        _ = fixture.personal.update(principle.id, text: "I don't relocate my family for work")
        XCTAssertEqual(sharedTexts(fixture.gate), ["I don't relocate my family for work"])

        _ = fixture.personal.update(principle.id, sharing: .lokalBotOnly)
        XCTAssertEqual(sharedTexts(fixture.gate), [])

        _ = fixture.personal.update(privateFact.id, sharing: .agents)
        _ = fixture.personal.forget([privateFact.id])
        XCTAssertEqual(sharedTexts(fixture.gate), [])

        _ = fixture.personal.update(principle.id, sharing: .agents)
        _ = fixture.personal.forgetAll()
        XCTAssertEqual(sharedTexts(fixture.gate), [])

        fixture.access.setEnabled(false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.gate.projectionURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.gate.accessMarkerURL.path))
    }

    func testMarkingUsedDoesNotRewriteTheProjection() throws {
        let fixture = makeFixture()
        let claim = try fixture.personal.remember("Answer in bullet points", origin: .added).get()
        fixture.access.setEnabled(true)
        _ = fixture.personal.update(claim.id, sharing: .agents)
        let written = try XCTUnwrap(fixture.gate.readProjection()?.generatedAt)

        clock = clock.addingTimeInterval(3_600)
        fixture.personal.markUsed([claim.id])
        XCTAssertEqual(fixture.gate.readProjection()?.generatedAt, written)
    }

    func testUnreadablePersonalModelSharesNothing() throws {
        let fixture = makeFixture()
        let claim = try fixture.personal.remember("Answer in bullet points", origin: .added).get()
        fixture.access.setEnabled(true)
        _ = fixture.personal.update(claim.id, sharing: .agents)
        XCTAssertEqual(sharedTexts(fixture.gate), ["Answer in bullet points"])

        let store = PersonalModelStore(root: root, encryptionKey: { [key] in key })
        try Data("corrupt".utf8).write(to: store.encryptedURL)
        fixture.personal.reload()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.gate.projectionURL.path))
        XCTAssertNotNil(fixture.access.lastError)
    }

    func testStartRemovesALeftoverProjectionWhenTheGrantIsOff() throws {
        let gate = PersonalContextAccessGate(root: root)
        try gate.enable()
        try gate.writeProjection(PersonalContextProjection(generatedAt: clock, claims: []))
        try FileManager.default.removeItem(at: gate.accessMarkerURL)

        let fixture = makeFixture()
        fixture.access.start()
        XCTAssertFalse(fixture.access.isEnabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: gate.projectionURL.path))
    }
}

final class PersonalContextToolTests: XCTestCase {
    private var root: URL!
    private let base = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersonalContextToolTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var provider: FileLibraryToolProvider {
        FileLibraryToolProvider(gate: AgentAccessGate(root: root)) { _ in .text("unused") }
    }

    private func claim(_ text: String, _ kind: PersonalClaimKind, minutes: Double,
                       alwaysUse: Bool = false) -> PersonalContextProjection.Claim {
        let date = base.addingTimeInterval(minutes * 60)
        return PersonalContextProjection.Claim(
            id: UUID(), kind: kind, text: text, alwaysUse: alwaysUse, source: .addedInSettings,
            createdAt: date, updatedAt: date)
    }

    private func share(_ claims: [PersonalContextProjection.Claim]) throws {
        let gate = PersonalContextAccessGate(root: root)
        try gate.enable()
        try gate.writeProjection(PersonalContextProjection(generatedAt: base, claims: claims))
    }

    private func items(_ result: ToolResult) throws -> [[String: Any]] {
        let object = try JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any]
        return try XCTUnwrap(object?["items"] as? [[String: Any]])
    }

    func testRefusedWithoutItsOwnGrantEvenWithOtherAccess() async throws {
        try AgentAccessGate(root: root).enable()
        try ScreenMemoryAccessGate(root: root).enable()
        let refused = await provider.call(name: "get_personal_context", arguments: ["task": "Plan my week"])
        XCTAssertTrue(refused.text.hasPrefix("[personal_context_disabled]"), refused.text)

        // A projection left on disk without the marker is never served.
        let gate = PersonalContextAccessGate(root: root)
        try gate.enable()
        try gate.writeProjection(PersonalContextProjection(generatedAt: base, claims: [claim("x", .fact, minutes: 0)]))
        try FileManager.default.removeItem(at: gate.accessMarkerURL)
        let stale = await provider.call(name: "get_personal_context", arguments: ["task": "Plan my week"])
        XCTAssertTrue(stale.text.hasPrefix("[personal_context_disabled]"), stale.text)
    }

    func testGrantWithoutProjectionIsUnavailable() async throws {
        try PersonalContextAccessGate(root: root).enable()
        let result = await provider.call(name: "get_personal_context", arguments: ["task": "Plan my week"])
        XCTAssertTrue(result.text.hasPrefix("[personal_context_unavailable]"), result.text)
    }

    func testReturnsRelevantSharedItemsFirstWithinTheLimit() async throws {
        let principle = claim("I don't take work that requires relocating my family", .principle, minutes: 1)
        let job = claim("I'm open to remote staff engineer roles", .fact, minutes: 2)
        let pet = claim("Our dog is called Luna", .fact, minutes: 3)
        let goal = claim("Ship LokalBot 1.0 this year", .goal, minutes: 4)
        try share([principle, job, pet, goal])

        let result = await provider.call(
            name: "get_personal_context",
            arguments: ["task": "Evaluate a staff engineer job offer in another country", "max_items": 2])
        XCTAssertFalse(result.isError, result.text)
        let returned = try items(result)
        XCTAssertEqual(returned.map { $0["text"] as? String }, [principle.text, job.text])
        XCTAssertEqual(returned.first?["authority"] as? String, "stated")
        XCTAssertEqual(returned.first?["kind"] as? String, "principle")
        XCTAssertTrue(result.text.contains("\"shared_count\" : 4"))
        XCTAssertTrue(result.text.contains("unknown, not false"))

        let goalsOnly = await provider.call(
            name: "get_personal_context", arguments: ["task": "Plan the quarter", "kinds": ["goal"]])
        XCTAssertEqual(try items(goalsOnly).map { $0["text"] as? String }, [goal.text])
    }

    func testInvalidArgumentsAreRejected() async throws {
        try share([claim("x", .fact, minutes: 0)])
        let cases: [JSONValue] = [
            [:],
            ["task": "  "],
            ["task": "Plan", "max_items": 13],
            ["task": "Plan", "max_items": "three"],
            ["task": "Plan", "kinds": ["values"]],
            ["task": "Plan", "kinds": "goal"],
        ]
        for arguments in cases {
            let result = await provider.call(name: "get_personal_context", arguments: arguments)
            XCTAssertTrue(result.text.hasPrefix("[invalid_arguments]"), "\(arguments): \(result.text)")
        }
    }
}
