import XCTest
@testable import LokalBot

private struct StubEngine: TextEngine {
    var reply: String
    var enumLimit: Int?
    var displayName: String { "Stub" }
    var structuredOutputEnumLimit: Int? { enumLimit }
    func generate(system: String, prompt: String, context: [String]) async throws -> String { reply }
}

final class ProjectStatusGeneratorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func meetingRef(_ title: String, daysAgo: Double, lines: [String]) -> ProjectProfile.MeetingRef {
        ProjectProfile.MeetingRef(id: UUID(), title: title, startedAt: now.addingTimeInterval(-daysAgo * 86_400),
                                  mentions: lines.map { ProjectProfile.Mention(text: $0, seek: nil) })
    }

    private func thread(_ text: String, owner: String, meetingDaysAgo: Double) -> ActionThread {
        let meeting = Meeting(id: UUID(), title: "Product Standup", appName: "Meet",
                              startedAt: now.addingTimeInterval(-meetingDaysAgo * 86_400),
                              endedAt: now.addingTimeInterval(-meetingDaysAgo * 86_400 + 1_800),
                              relativePath: "meetings/\(UUID().uuidString)")
        let outcomes = MeetingOutcomes(actionItems: [.init(text: text, owner: owner)])
        let projection = MeetingOutcomeProjection(meeting: meeting, outcomes: outcomes, state: MeetingOutcomeState(),
                                                  followUp: FollowUpDraft.seeded(for: meeting, outcomes: outcomes))
        return ActionThreadClusterer.cluster(projection.actionReferences)[0]
    }

    private func project(meetings: [ProjectProfile.MeetingRef], myActions: [ActionThread] = [],
                         othersActions: [ActionThread] = [],
                         reviewNotes: [ProjectProfile.ReviewNote] = []) -> ProjectProfile {
        ProjectProfile(id: "tracked:x", name: "Larkspur", kind: .tracked(UUID()), otherNames: ["Heron vault"],
                       meetings: meetings, myActions: myActions, othersActions: othersActions,
                       olderOthersActions: [], decisions: [], reviewNotes: reviewNotes, days: [], windows: [],
                       people: [], lastActive: meetings.first?.startedAt)
    }

    func testEvidenceLabelsNewestFirstAndNamesOwnersWithoutTodaysDate() {
        let newest = meetingRef("Product Standup", daysAgo: 4, lines: ["Larkspur pilot passed the synthetic review."])
        let older = meetingRef("Demo Day", daysAgo: 14, lines: ["Larkspur rollout plan was shared."])
        let mine = thread("Write the synthetic Larkspur memo", owner: "Me", meetingDaysAgo: 4)
        let theirs = thread("Send the synthetic Larkspur guide", owner: "Them 8", meetingDaysAgo: 4)
        let note = ProjectProfile.ReviewNote(name: "Larkspur vault", status: "Spec drafted.", lastActiveDay: "2026-05-27")
        let evidence = ProjectStatusGenerator.evidence(for: project(
            meetings: [newest, older], myActions: [mine], othersActions: [theirs], reviewNotes: [note]))

        XCTAssertEqual(evidence.meetings.map(\.label), ["M1", "M2"])
        XCTAssertEqual(evidence.meetings.first?.title, "Product Standup")
        XCTAssertEqual(evidence.meetingIDs, [newest.id, older.id])
        let context = ProjectStatusGenerator.promptContext(evidence)
        XCTAssertTrue(context.hasPrefix("Project: Larkspur (also called Heron vault)"))
        XCTAssertTrue(context.contains("M1 · Product Standup"))
        XCTAssertTrue(context.contains("- Larkspur pilot passed the synthetic review."))
        XCTAssertTrue(context.contains("owner: the user"))
        XCTAssertFalse(context.contains("Them 8"))
        XCTAssertTrue(context.contains("Larkspur vault (last active 2026-05-27): Spec drafted."))
        XCTAssertFalse(context.contains(now.formatted(.dateTime.day().month(.abbreviated).year())))
    }

    func testFingerprintChangesOnlyWithTheEvidence() {
        let first = meetingRef("Product Standup", daysAgo: 4, lines: ["Larkspur pilot passed review."])
        let evidence = ProjectStatusGenerator.evidence(for: project(meetings: [first]))
        XCTAssertEqual(ProjectStatusGenerator.fingerprint(evidence),
                       ProjectStatusGenerator.fingerprint(ProjectStatusGenerator.evidence(for: project(meetings: [first]))))
        let newer = meetingRef("Product Standup", daysAgo: 1, lines: ["Larkspur is paused."])
        XCTAssertNotEqual(ProjectStatusGenerator.fingerprint(evidence),
                          ProjectStatusGenerator.fingerprint(ProjectStatusGenerator.evidence(for: project(meetings: [newer, first]))))
    }

    func testGenerateMapsSourcesToMeetingsAndRejectsUnreadableReplies() async throws {
        let newest = meetingRef("Product Standup", daysAgo: 4, lines: ["Larkspur pilot passed the synthetic review."])
        let older = meetingRef("Demo Day", daysAgo: 14, lines: ["Larkspur rollout plan was shared."])
        let evidence = ProjectStatusGenerator.evidence(for: project(meetings: [newest, older]))
        let projectID = UUID()
        let reply = """
            {"overview": "The pilot passed review; pricing is still open.",
             "points": [{"text": "Pilot passed review.", "source": "M1"},
                        {"text": "Rollout plan shared.", "source": "m2"},
                        {"text": "Vault spec drafted.", "source": "review"},
                        {"text": "Pilot passed review.", "source": "M1"}],
             "open_questions": ["Will pricing settle this month?", " "]}
            """
        let summary = try await ProjectStatusGenerator.generate(
            evidence: evidence, projectID: projectID, engine: StubEngine(reply: reply),
            location: "this Mac", now: now)

        XCTAssertEqual(summary.projectID, projectID)
        XCTAssertEqual(summary.overview, "The pilot passed review; pricing is still open.")
        XCTAssertEqual(summary.points.map(\.text),
                       ["Pilot passed review.", "Rollout plan shared.", "Vault spec drafted."])
        XCTAssertEqual(summary.points.map(\.meetingID), [newest.id, older.id, nil])
        XCTAssertEqual(summary.points.first?.meetingTitle, "Product Standup")
        XCTAssertEqual(summary.openQuestions, ["Will pricing settle this month?"])
        XCTAssertEqual(summary.meetingIDs, [newest.id, older.id])
        XCTAssertEqual(summary.evidenceFingerprint, ProjectStatusGenerator.fingerprint(evidence))
        XCTAssertEqual(summary.engineName, "Stub")
        XCTAssertEqual(summary.generatedAt, now)

        do {
            _ = try await ProjectStatusGenerator.generate(
                evidence: evidence, projectID: projectID, engine: StubEngine(reply: "not json"), location: "this Mac")
            XCTFail("An unreadable reply must not become a note")
        } catch ProjectStatusGenerator.GenerationError.unreadableResponse {}

        do {
            _ = try await ProjectStatusGenerator.generate(
                evidence: ProjectStatusGenerator.evidence(for: project(meetings: [])), projectID: projectID,
                engine: StubEngine(reply: reply), location: "this Mac")
            XCTFail("A project with no evidence gets no note")
        } catch ProjectStatusGenerator.GenerationError.emptyEvidence {}
    }

    func testSchemaListsSourcesOnlyWithinTheEnumLimit() throws {
        func sourceEnum(_ schema: [String: Any]) -> [String]? {
            let properties = schema["properties"] as? [String: Any]
            let points = properties?["points"] as? [String: Any]
            let items = points?["items"] as? [String: Any]
            let itemProperties = items?["properties"] as? [String: Any]
            return (itemProperties?["source"] as? [String: Any])?["enum"] as? [String]
        }
        XCTAssertEqual(sourceEnum(ProjectStatusGenerator.schema(labels: ["M1", "M2"], enumLimit: nil)),
                       ["M1", "M2", "review"])
        XCTAssertNil(sourceEnum(ProjectStatusGenerator.schema(labels: ["M1", "M2"], enumLimit: 2)))
    }
}
