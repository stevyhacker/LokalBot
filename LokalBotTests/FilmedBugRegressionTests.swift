import AppKit
import FluidAudio
import SwiftUI
import XCTest
@testable import LokalBot

/// Bugs the landing page films exposed on real footage (2026-11-05). Each
/// expectation is the filmed input and what should have come out of it.
final class FilmedBugRegressionTests: XCTestCase {
    // MARK: - Transcript

    private func token(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> TokenTiming {
        TokenTiming(token: text, tokenId: 0, startTime: start, endTime: end, confidence: 0.9)
    }

    func testPunctuationTimedAfterAPauseStaysWithItsSentence() {
        let result = ASRResult(text: "", confidence: 0.9, duration: 8, processingTime: 0, tokenTimings: [
            token("Great", 0, 0.5), token(" by", 0.6, 0.8), token(" Wednesday", 0.9, 1.4),
            token(".", 3.0, 3.1),
            token(" Are", 3.2, 3.4), token(" we", 3.5, 3.6), token(" keeping", 3.7, 4.0), token("?", 4.1, 4.2),
        ])
        let segments = ParakeetEngine.segments(from: result, speaker: "them")
        XCTAssertEqual(segments.map(\.text), ["Great by Wednesday.", "Are we keeping?"])
        XCTAssertEqual(segments.first?.end, 1.4, "the pause after the words is not part of the segment")
        XCTAssertEqual(segments.last?.start, 3.2)
    }

    func testAPauseStillSplitsWhenNoPunctuationArrives() {
        let result = ASRResult(text: "", confidence: 0.9, duration: 8, processingTime: 0, tokenTimings: [
            token("One", 0, 0.5), token(" Two", 2.0, 2.5),
        ])
        XCTAssertEqual(ParakeetEngine.segments(from: result, speaker: "them").map(\.text), ["One", "Two"])
    }

    // MARK: - Decisions

    func testStatedDecisionsComeFromTheFilmedLines() {
        XCTAssertEqual(ExplicitDecisions.statements(
            in: "Agreed. Decision made, we shoot in the studio, can you book it for the 12th?"),
            ["We shoot in the studio."])
        XCTAssertEqual(ExplicitDecisions.statements(in: "Yes, we decided the launch stays on the 20th."),
                       ["We decided the launch stays on the 20th."])
    }

    func testOpenOrPastWordingIsNotADecision() {
        for line in [
            "Let's decide that after the test shoot on Monday",
            "Have we decided on the venue?",
            "If we decided to move it, the crew would need a week.",
            "We haven't decided on the second camera yet.",
            "Last year we decided to move the launch to the spring.",
            "There was no decision, we ran out of time.",
        ] {
            XCTAssertEqual(ExplicitDecisions.statements(in: line), [], line)
        }
    }

    func testValidatedNotesGainAStatedDecisionTheModelFiledElsewhere() throws {
        let transcript = Transcript(segments: [
            .init(start: 0, end: 5, speaker: "Me", text: "Are we shooting on location or in the studio?"),
            .init(start: 6, end: 10, speaker: "Them", text: "The studio, it's half the budget."),
            .init(start: 11, end: 15, speaker: "Me", text: "Agreed. Decision made, we shoot in the studio."),
        ], engine: "test")
        let evidence = MeetingNotesEvidence(transcript: transcript)
        let keyPoint: [String: Any] = ["section": "Key points", "text": "The studio costs half as much.",
                                       "source": evidence.units[1].source]
        let output = String(decoding: try JSONSerialization.data(withJSONObject: [
            "notes": [keyPoint], "actions": [[String: Any]](), "has_more": false,
        ] as [String: Any]), as: UTF8.self)
        let result = evidence.validate(output, units: evidence.units, template: .meeting, meetingID: UUID(),
                                       maximumNotes: 12, maximumActions: 10)
        XCTAssertEqual(result.outcomes.decisionRecords.map(\.text), ["We shoot in the studio."])
        XCTAssertEqual(result.outcomes.decisionRecords.first?.citations.first?.excerpt,
                       "Agreed. Decision made, we shoot in the studio.")
    }

    func testAModelDecisionOnTheSameFactIsNotDoubled() throws {
        let rows = ["s1": "Decision made, we shoot in the studio."]
        let notes: [[String: Any]] = [["section": "Decisions", "text": "We shoot in the studio", "source": "s0"]]
        XCTAssertTrue(ExplicitDecisions.missing(from: notes, in: rows).isEmpty)
    }

    // MARK: - Ask streaming

    func testStreamingTextHidesMarkersStillArriving() {
        XCTAssertEqual(StreamingMarkdown.displayable("Plain so far"), "Plain so far")
        XCTAssertEqual(StreamingMarkdown.displayable("The **studio"), "The **studio**")
        XCTAssertEqual(StreamingMarkdown.displayable("The **"), "The ")
        XCTAssertEqual(StreamingMarkdown.displayable("The **studio*"), "The **studio**")
        XCTAssertEqual(StreamingMarkdown.displayable("The **studio**"), "The **studio**")
        XCTAssertEqual(StreamingMarkdown.displayable("Run `make"), "Run `make`")
        XCTAssertEqual(StreamingMarkdown.displayable("An *aside"), "An *aside*")
        XCTAssertEqual(StreamingMarkdown.displayable("2 * 3"), "2 * 3")
        XCTAssertEqual(StreamingMarkdown.displayable("* item"), "* item")
        XCTAssertEqual(StreamingMarkdown.displayable("```\ncode **"), "```\ncode **")
        XCTAssertEqual(StreamingMarkdown.displayable("**Done** first\n\nThen **next"), "**Done** first\n\nThen **next**")
    }

    func testPartialBoldRendersWithNoMarkersOnScreen() {
        let rendered = SelectableDigestText.attributedText(from: StreamingMarkdown.displayable("Shoot in the **studio"),
                                                           style: .editorial)
        XCTAssertEqual(String(rendered.characters), "Shoot in the studio")
    }

    // MARK: - Compose

    private func screen(window: String = "Spring campaign — Edited") -> DictationScreenContext {
        DictationScreenContext(appName: "TextEdit", bundleID: "com.apple.TextEdit", windowTitle: window, visibleText: "")
    }

    func testComposeDropsAWindowTitleEchoedAsTheFirstLine() {
        XCTAssertEqual(DictationComposePrompt.insertableText(
            "Spring campaign — Edited\nHi Sam, the shoot is on the 12th.",
            spokenText: "Reply that the shoot is on the 12th", context: screen()),
            "Hi Sam, the shoot is on the 12th.")
        XCTAssertEqual(DictationComposePrompt.insertableText(
            "# Spring campaign — Edited\n\nHi Sam.", spokenText: "Say hi to Sam", context: screen()), "Hi Sam.")
        XCTAssertEqual(DictationComposePrompt.insertableText(
            "Window: Spring campaign — Edited", spokenText: "Reply yes", context: screen()), "",
            "nothing but the title is an empty result, which Compose reports instead of inserting it")
    }

    func testComposeKeepsATitleThePersonAskedFor() {
        XCTAssertEqual(DictationComposePrompt.insertableText(
            "Spring campaign — Edited\nNext line", spokenText: "Write spring campaign — edited as a heading",
            context: screen()), "Spring campaign — Edited\nNext line")
    }

    func testComposeWritesPlainTextUnlessMarkdownWasAsked() {
        let markdown = "## Plan\nWe **shoot** in the *studio* on __Monday__.\n- 2 * 3 stays\n* bullets stay"
        XCTAssertEqual(DictationComposePrompt.insertableText(markdown, spokenText: "Draft the plan", context: nil),
                       "Plan\nWe shoot in the studio on Monday.\n- 2 * 3 stays\n* bullets stay")
        XCTAssertEqual(DictationComposePrompt.insertableText(markdown, spokenText: "Draft the plan in markdown", context: nil),
                       markdown)
        XCTAssertEqual(DictationComposePrompt.insertableText("```\n**keep**\n```", spokenText: "Draft it", context: nil),
                       "```\n**keep**\n```")
    }

    // MARK: - Model server

    func testAFreshlyBootedMacGetsMinutesToLoadAModel() {
        let seconds = Double(LlamaServer.startupHealthAttempts)
            * Double(LlamaServer.startupHealthInterval.components.seconds * 1_000
                     + LlamaServer.startupHealthInterval.components.attoseconds / 1_000_000_000_000_000) / 1_000
        XCTAssertEqual(seconds, 300, accuracy: 0.001)
    }

    // MARK: - Topics

    func testHardwareAcronymsAreNotSuggestedProjects() {
        let meetings = (1...4).map { index in
            Meeting(id: UUID(), title: "Weekly sync", appName: "Meet",
                    startedAt: Date(timeIntervalSince1970: 1_780_000_000 + Double(index) * 86_400),
                    endedAt: Date(timeIntervalSince1970: 1_780_001_800 + Double(index) * 86_400),
                    relativePath: "meetings/\(index)")
        }
        var summaries: [UUID: String] = [:]
        for meeting in meetings {
            summaries[meeting.id] = "## Notes\n- The render machine needs a bigger SSD before Kestrel ships."
        }
        let topics = ProjectTopicDetector.topics(meetings: meetings, summaries: summaries, projections: [], excludedWords: [])
        XCTAssertEqual(topics.map(\.name), ["Kestrel"])
    }

    // MARK: - Project notes

    func testEvidenceFormatIsRemovedFromANote() {
        XCTAssertEqual(ProjectStatusGenerator.removingEvidenceFormat(
            "Book the studio (owner: Other speaker, due: Friday, open)."), "Book the studio.")
        XCTAssertEqual(ProjectStatusGenerator.removingEvidenceFormat(
            "Send the shot list, owner: Other speaker, open"), "Send the shot list")
        XCTAssertEqual(ProjectStatusGenerator.removingEvidenceFormat("Waiting on the script (deferred)."),
                       "Waiting on the script.")
        let ownWords = "The owner of the shoot is still open to a second camera (see the budget)."
        XCTAssertEqual(ProjectStatusGenerator.removingEvidenceFormat(ownWords), ownWords)
    }

    private struct NoteReply: TextEngine {
        var displayName: String { "Stub" }
        let onGenerate: @Sendable () -> Void
        func generate(system: String, prompt: String, context: [String]) async throws -> String {
            onGenerate()
            return #"{"overview": "Book it (owner: Sam, open).", "points": [], "open_questions": []}"#
        }
    }

    func testANoteIsStampedWhenWritingFinishes() async throws {
        let started = Date(timeIntervalSince1970: 1_780_000_000)
        let finished = started.addingTimeInterval(480)
        let evidence = ProjectStatusGenerator.Evidence(
            projectName: "Northwind", otherNames: [],
            meetings: [.init(id: UUID(), label: "M1", title: "Call", date: started, lines: ["Northwind passed."],
                             decisions: [], actions: [])],
            otherActions: [], reviewNotes: [])
        let summary = try await ProjectStatusGenerator.generate(
            evidence: evidence, projectID: UUID(), engine: NoteReply(onGenerate: {}), location: "this Mac",
            now: started, finishedAt: { finished })
        XCTAssertEqual(summary.generatedAt, finished)
        XCTAssertEqual(summary.overview, "Book it.")
    }

    private func profile(id: String, name: String, kind: ProjectProfile.Kind) -> ProjectProfile {
        ProjectProfile(id: id, name: name, kind: kind, otherNames: [], meetings: [], myActions: [], othersActions: [],
                       olderOthersActions: [], decisions: [], reviewNotes: [], days: [], windows: [], people: [],
                       lastActive: nil)
    }

    func testAJustTrackedSuggestionStaysOnScreenAsTracked() throws {
        let trackedID = UUID()
        let selection = ProjectsWorkspaceView.trackedSelectionID(trackedID)
        var curation = ProjectCuration()
        curation.tracked = [.init(id: trackedID, name: "Northwind", otherNames: [], createdAt: Date())]
        let suggestion = profile(id: "topic:northwind", name: "Northwind", kind: .suggestedTopic)
        let settling = try XCTUnwrap(ProjectsWorkspaceView.settlingProfile(
            selection: selection, curation: curation, projects: [suggestion]))
        XCTAssertEqual(settling.id, selection)
        XCTAssertEqual(settling.trackedID, trackedID)
        XCTAssertEqual(settling.name, "Northwind")
        let refreshed = profile(id: selection, name: "Northwind", kind: .tracked(trackedID))
        XCTAssertNil(ProjectsWorkspaceView.settlingProfile(selection: selection, curation: curation, projects: [refreshed]),
                     "the refreshed profile takes over")
    }
}

@MainActor
final class ProjectWritingStateTests: XCTestCase {
    private struct Never: TextEngine {
        var displayName: String { "Stub" }
        func generate(system: String, prompt: String, context: [String]) async throws -> String {
            #"{"overview": "Passed review.", "points": [], "open_questions": []}"#
        }
    }

    func testWritingIsVisibleBeforeTheWriteTaskRuns() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectWritingStateTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProjectStore(directory: directory)
        let id = try XCTUnwrap(store.track(name: "Larkspur"))
        let project = ProjectProfile(
            id: "tracked:" + id.uuidString, name: "Larkspur", kind: .tracked(id), otherNames: [],
            meetings: [.init(id: UUID(), title: "Standup", startedAt: Date(),
                             mentions: [.init(text: "Larkspur passed review.", seek: nil)])],
            myActions: [], othersActions: [], olderOthersActions: [], decisions: [], reviewNotes: [],
            days: [], windows: [], people: [], lastActive: nil)
        let task = store.startWritingSummary(for: project, automatic: true, location: "this Mac") { Never() }
        // No suspension point since the call: a view updating now already sees it.
        XCTAssertTrue(store.writing.contains(id))
        await task?.value
        XCTAssertFalse(store.writing.contains(id))
        XCTAssertNotNil(store.summaries[id])
    }
}
