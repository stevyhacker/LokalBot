import Foundation
@testable import LokalBot

/// A small synthetic library for companion-record tests. It deliberately
/// holds every kind of private data that must never reach a phone, each
/// marked with a distinctive string listed in `secrets`.
struct CompanionFixtureLibrary {
    let root: URL
    let now: Date
    let calendar = Calendar.current
    /// The day of the main meeting, at local noon.
    let day: Date
    let designReview: Meeting
    let olderMeeting: Meeting
    let mergedSource: Meeting
    let mergedParent: Meeting
    let sampleMeeting: Meeting
    let projectID = UUID(uuidString: "7A1D0C55-2B8F-4F3A-A6C4-5E6F7A8B9C01")!
    let screenshotID: Int64

    static let windowTitleSecret = "Quarterly-forecast-WINDOWTITLE-SECRET.xlsx"
    static let ocrSecret = "OCR-SCREEN-TEXT-SECRET account 4417"
    static let screenshotPathSecret = "SCREENSHOT-PATH-SECRET.heic.enc"
    static let attendeeEmailSecret = "maya.chen.attendee-secret@example-private.test"
    static let unnamedAttendeeEmail = "zed@unnamed-attendee-secret.test"
    static let voiceProfileSecret = "VOICE-PROFILE-EVIDENCE-SECRET"
    static let calendarIdentitySecret = "calendar-identity-SECRET-42"
    static let agendaSecret = "AGENDA-SECRET dial-in 555-0100"
    static let meetingURLSecret = "https://zoom.example.test/j/MEETINGURL-SECRET"
    static let dreamSecret = "DREAM-MEMORY-SECRET project goal"
    static let personalContextSecret = "PERSONAL-CONTEXT-SECRET likes"
    static let reviewNoteSecret = "OVERNIGHT-REVIEW-NOTE-SECRET"

    /// Strings that must never appear in any record body.
    static let secrets = [
        ocrSecret, "account 4417", screenshotPathSecret, attendeeEmailSecret, "example-private.test",
        unnamedAttendeeEmail, "unnamed-attendee-secret.test", voiceProfileSecret, calendarIdentitySecret,
        agendaSecret, "MEETINGURL-SECRET", dreamSecret, personalContextSecret, reviewNoteSecret,
        "speaker-evidence", "attribution", "speakerCalendarIdentityIDs",
    ]

    var activityDatabaseURL: URL { root.appendingPathComponent("lokalbotv3.sqlite") }

    var dayKey: String { DreamDay.key(for: day, calendar: calendar) }

    static func make() throws -> CompanionFixtureLibrary {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let now = calendar.date(byAdding: .hour, value: 18, to: today)!
        let day = calendar.date(byAdding: .hour, value: 12, to: calendar.date(byAdding: .day, value: -2, to: today)!)!
        let storage = StorageManager(rootURL: root)

        // The main meeting: calendar attendees with emails, an agenda, a link.
        var designReview = Meeting(
            id: UUID(uuidString: "3F6C2A10-8A4E-4D2B-9B1E-0A1B2C3D4E01")!,
            title: "Design review — onboarding", appName: "Zoom",
            startedAt: day.addingTimeInterval(-3600), endedAt: day.addingTimeInterval(-3600 + 2520),
            relativePath: try storage.reserveMeetingFolder(title: "Design review", startedAt: day))
        designReview.recordedDuration = 2520
        designReview.calendarTitle = "Design review — onboarding"
        designReview.meetingURL = URL(string: meetingURLSecret)
        designReview.calendarAgenda = agendaSecret
        designReview.participantNameHints = ["Maya Chen"]
        designReview.calendarParticipantIdentities = [
            CalendarParticipantIdentity(id: calendarIdentitySecret, name: "Maya Chen", emailAddress: attendeeEmailSecret)!,
            CalendarParticipantIdentity(id: "cal-2", name: nil, emailAddress: unnamedAttendeeEmail)!,
        ]
        try storage.saveMeta(designReview)
        let folder = designReview.folderURL(in: storage)
        var transcript = Transcript(segments: [
            .init(start: 0, end: 9, speaker: "me", text: "Let's cut onboarding to three steps.",
                  attribution: SpeakerAttribution(source: .microphone, identity: .user, method: .track)),
            .init(start: 721.4, end: 728.9, speaker: "them 1",
                  text: "Could you send me the revised deck by Thursday?",
                  attribution: SpeakerAttribution(source: .system, identity: .other, method: .diarization)),
            .init(start: 730, end: 734, speaker: "them 2", text: "Agreed, three steps.",
                  attribution: SpeakerAttribution(source: .system, identity: .other, method: .diarization)),
        ], engine: "fixture")
        transcript.setSpeakerAlias("Maya Chen", for: "them 1", calendarIdentityID: calendarIdentitySecret)
        try JSONEncoder().encode(transcript).write(to: folder.appendingPathComponent("transcript.json"))
        try Data("""
            # Design review — onboarding — October 30, 2026 at 10:30
            **Duration:** 42 min · **App:** Zoom · **Words:** 120 · **Template:** Meeting · **Model:** Fixture

            ## Recap
            We agreed to cut onboarding to three steps.
            """.utf8).write(to: folder.appendingPathComponent("summary.md"))
        try Data("- Maya wants to lead the next design review".utf8)
            .write(to: folder.appendingPathComponent("notes.md"))
        let deckAction = MeetingOutcomes.ActionItem(
            id: "act-deck", text: "Send the revised pricing deck to Maya", owner: "Me", due: "2026-11-03",
            isForUser: true, importance: 4,
            citations: [OutcomeSourceCitation(meetingID: designReview.id, segmentID: "s2", start: 721.4, end: 728.9,
                                              speaker: "them 1", excerpt: "Could you send me the revised deck by Thursday?")])
        let studyAction = MeetingOutcomes.ActionItem(
            id: "act-study", text: "Confirm the study participants", owner: nil, isForUser: nil, importance: 3)
        var outcomes = MeetingOutcomes(actionItems: [deckAction, studyAction],
                                       openQuestions: ["Which five customers go first?"])
        outcomes.decisionRecords = [MeetingOutcomes.Decision(id: "dec-flag", text: "Ship the three-step flow behind a flag first.")]
        try outcomes.write(to: folder)
        var state = MeetingOutcomeState()
        state.actions["act-study"] = .init(status: .deferred, userEdited: true)
        try MeetingOutcomeStore.writeState(state, to: folder)
        // Private speaker evidence beside the meeting; never read by builders.
        let evidence = folder.appendingPathComponent("speaker-evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        try Data(voiceProfileSecret.utf8).write(to: evidence.appendingPathComponent("assignments.sealed"))

        // An older meeting, outside a 30-day window.
        let olderDay = calendar.date(byAdding: .day, value: -45, to: day)!
        let olderMeeting = Meeting(
            id: UUID(uuidString: "3F6C2A10-8A4E-4D2B-9B1E-0A1B2C3D4E02")!,
            title: "Pricing workshop", appName: "Google Meet",
            startedAt: olderDay, endedAt: olderDay.addingTimeInterval(1800),
            relativePath: try storage.reserveMeetingFolder(title: "Pricing workshop", startedAt: olderDay))
        try storage.saveMeta(olderMeeting)

        // A merge: the source is folded into the parent and never shared.
        let mergedSourceID = UUID(uuidString: "3F6C2A10-8A4E-4D2B-9B1E-0A1B2C3D4E03")!
        let mergedParentID = UUID(uuidString: "3F6C2A10-8A4E-4D2B-9B1E-0A1B2C3D4E04")!
        var mergedSource = Meeting(
            id: mergedSourceID, title: "Standup part 1", appName: "Zoom",
            startedAt: day.addingTimeInterval(-7200), endedAt: day.addingTimeInterval(-6900),
            relativePath: try storage.reserveMeetingFolder(title: "Standup part 1", startedAt: day))
        mergedSource.mergedIntoMeetingID = mergedParentID
        try storage.saveMeta(mergedSource)
        var mergedParent = Meeting(
            id: mergedParentID, title: "Standup", appName: "Zoom",
            startedAt: day.addingTimeInterval(-7200), endedAt: day.addingTimeInterval(-6600),
            relativePath: try storage.reserveMeetingFolder(title: "Standup", startedAt: day))
        mergedParent.mergedSourceMeetingIDs = [mergedSourceID]
        try storage.saveMeta(mergedParent)

        // LokalBot's bundled sample meeting is made up and never shared.
        var sampleMeeting = Meeting(
            id: UUID(uuidString: "3F6C2A10-8A4E-4D2B-9B1E-0A1B2C3D4E05")!,
            title: "Orders API sample", appName: "Sample",
            startedAt: day.addingTimeInterval(-10000), endedAt: day.addingTimeInterval(-9000),
            relativePath: try storage.reserveMeetingFolder(title: "Orders API sample", startedAt: day))
        sampleMeeting.sampleID = "orders-api/en"
        try storage.saveMeta(sampleMeeting)

        // Activity: window titles, a screenshot with a path and OCR text, a
        // saved moment, and a coding-agent burst.
        let activity = ActivityStore(databaseURL: root.appendingPathComponent("lokalbotv3.sqlite"))
        activity.insert(ActivityBlock(app: "Numbers", title: windowTitleSecret,
                                      start: day.addingTimeInterval(1800), end: day.addingTimeInterval(1800 + 1500)))
        activity.insert(ActivityBlock(app: "Xcode", title: "OnboardingFlow.swift",
                                      start: day.addingTimeInterval(3400), end: day.addingTimeInterval(3400 + 1200)))
        let screenshotID = try activity.insertScreenshot(
            ts: day.addingTimeInterval(2000), path: "activity/\(screenshotPathSecret)", app: "Numbers",
            windowTitle: windowTitleSecret, ocr: ocrSecret)
        try activity.saveMoment(snapshotID: screenshotID, note: "Pricing table idea")
        try activity.upsertCodingAgentBursts([CodingAgentBurst(
            agent: .claudeCode, sessionID: "fixture-session", title: "Onboarding step reducer",
            project: "onboarding", branch: "main",
            start: day.addingTimeInterval(4000), end: day.addingTimeInterval(4900), activeDuration: 900,
            prompts: ["shorten the onboarding flow"], promptCount: 1, finalReply: nil,
            changedFiles: [], changedFileCount: 0, actions: [], pullRequests: [], toolCallCount: 3)])

        // The day's digest, with the evidence log LokalBot renders from capture.
        let journal = root.appendingPathComponent("journal", isDirectory: true)
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
        try Data("""
            ## Day summary

            ### At a glance
            - Reviewed the prototype with Maya [screen:\(screenshotID)].
            - Northwind accepted the annual plan.

            ### Tasks
            - **Send the pricing deck** — In progress. Drafted the tiers.

            ### Decisions and next steps
            - Decision: Ship behind a feature flag first.
            - Blocker: Waiting on legal counsel.

            ## Meetings

            ### 10:30 — Design review — onboarding
            - App: Zoom

            ## Time allocation

            | App | Tracked time |
            | --- | ---: |
            | Numbers | 25m |

            ## Full activity log

            - **12:30–12:55** — **Numbers** — \(windowTitleSecret)
              - [screen:\(screenshotID)], 12:33: \(ocrSecret)
            """.utf8).write(to: journal.appendingPathComponent("\(DreamDay.key(for: day, calendar: calendar)).md"))

        // Tracked project with a "Where it stands" note; one point came from
        // overnight review notes, which stay on the Mac.
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let projectID = UUID(uuidString: "7A1D0C55-2B8F-4F3A-A6C4-5E6F7A8B9C01")!
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(ProjectCuration(tracked: [
            .init(id: projectID, name: "Onboarding", otherNames: [], createdAt: day.addingTimeInterval(-86_400 * 10)),
        ])).write(to: projects.appendingPathComponent(ProjectCuration.fileName))
        try encoder.encode([ProjectStatusSummary(
            projectID: projectID, overview: "Onboarding is on track.",
            points: [
                .init(text: "Three steps agreed.", meetingID: designReview.id,
                      meetingTitle: designReview.title, meetingDate: designReview.startedAt),
                .init(text: reviewNoteSecret, meetingID: nil, meetingTitle: nil, meetingDate: nil),
            ],
            openQuestions: [], meetingIDs: [designReview.id], evidenceFingerprint: "fixture",
            generatedAt: day, engineName: "Fixture", location: "this Mac"),
        ]).write(to: projects.appendingPathComponent(ProjectStatusSummary.fileName))

        // Dream memory and Personal Context files: never read.
        let memory = root.appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true)
        try Data("{\"projects\":[{\"name\":\"\(dreamSecret)\"}]}".utf8).write(to: memory.appendingPathComponent("memory.json"))
        try Data(personalContextSecret.utf8).write(to: memory.appendingPathComponent("personal-model.json.enc"))

        return CompanionFixtureLibrary(
            root: root, now: now, day: day, designReview: designReview, olderMeeting: olderMeeting,
            mergedSource: mergedSource, mergedParent: mergedParent, sampleMeeting: sampleMeeting,
            screenshotID: screenshotID)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func library(_ sharing: CompanionSharing = CompanionSharing()) -> CompanionLibrary {
        CompanionLibrary.load(root: root, activityDatabaseURL: activityDatabaseURL,
                              scope: sharing.recordScope, now: now, calendar: calendar)
    }

    func records(_ sharing: CompanionSharing = CompanionSharing()) -> [CompanionRecord] {
        CompanionRecordBuilder(
            library: library(sharing),
            activity: ActivityStore(databaseURL: activityDatabaseURL, readOnly: true)).allRecords()
    }
}

/// The host's record store, reduced to what the publisher relies on.
final class InMemoryCompanionSink: CompanionRecordSink {
    private(set) var records: [String: [String: String]] = [:]
    private(set) var manifest: String?
    private(set) var tombstones: [(kind: String, key: String)] = []

    func publish(kind: String, key: String, bodyJSON: String) throws -> Bool {
        guard records[kind]?[key] != bodyJSON else { return false }
        records[kind, default: [:]][key] = bodyJSON
        return true
    }

    func remove(kind: String, key: String) throws -> Bool {
        guard records[kind]?[key] != nil else { return false }
        records[kind]?[key] = nil
        tombstones.append((kind, key))
        return true
    }

    func recordKeys(kind: String) throws -> [String] {
        Array((records[kind] ?? [:]).keys)
    }

    func setManifest(bodyJSON: String) throws {
        manifest = bodyJSON
    }

    func body(_ kind: CompanionRecordKind, _ key: String) -> [String: Any]? {
        guard let json = records[kind.rawValue]?[key] else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    }
}
