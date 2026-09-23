import Foundation
import AVFoundation
import SQLite3
import CryptoKit

/// Plants a self-contained LokalBot storage root on disk for one UI test run.
/// Mirrors `StorageManager`'s on-disk layout
/// (`meetings/YYYY/MM/dd-slug/{meta.json, transcript.json, transcript.md, summary.md}`)
/// without `@testable`-importing the app — the UI test bundle runs out-of-process,
/// so it stays decoupled and only the file shape matters.
///
/// Every meeting is deterministic: stable UUIDs, stable text, and dates anchored
/// to local midday so the grouping headers always read "TODAY" / "YESTERDAY".
enum SyntheticFixture {

    static let todayDigestMarker = "Current-day digest marker"
    static let previousDayDigestMarker = "Previous-day digest marker"

    static func plantActivityMoment(in library: Library) throws {
        var db: OpaquePointer?
        guard sqlite3_open(library.root.appendingPathComponent("lokalbotv3.sqlite").path, &db) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(db) }
        let timestamp = library.designReview.startedAt.addingTimeInterval(-105 * 60).timeIntervalSince1970
        let sql = """
            CREATE TABLE IF NOT EXISTS screenshots (
                id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL NOT NULL, path TEXT NOT NULL, app TEXT NOT NULL,
                window_title TEXT NOT NULL DEFAULT '', capture_trigger TEXT NOT NULL DEFAULT 'interval',
                perceptual_hash TEXT NOT NULL DEFAULT '', similarity_group INTEGER NOT NULL DEFAULT 0,
                source_url TEXT NOT NULL DEFAULT '', document_name TEXT NOT NULL DEFAULT '',
                meeting_id TEXT NOT NULL DEFAULT '', privacy_redactions INTEGER NOT NULL DEFAULT 0);
            INSERT INTO screenshots (id, ts, path, app, window_title)
                VALUES (9001, \(timestamp), '', 'Xcode', 'TimelineView.swift');
            """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    }

    static func makeNotesPartial(for meeting: Meeting, in library: Library) throws {
        let folder = library.folder(for: meeting)
        // These synthetic transcripts contain only engine and plain segments,
        // so their canonical encoding is the sorted persisted JSON object.
        let transcript = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("transcript.json")))
        let canonical = try JSONSerialization.data(withJSONObject: transcript, options: [.sortedKeys])
        let revision = SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
        guard var outcomes = try JSONSerialization.jsonObject(with:
            Data(contentsOf: folder.appendingPathComponent("outcomes.json"))) as? [String: Any] else { return }
        outcomes["transcriptRevision"] = revision
        let snapshot: [String: Any] = [
            "version": 1, "transcriptRevision": revision, "outcomes": outcomes,
            "summary": "## TL;DR\n\n- **You:** Redis was selected for the caching layer.",
            "completedParts": 1, "totalParts": 2, "template": "meeting",
        ]
        try JSONSerialization.data(withJSONObject: snapshot).write(to: folder.appendingPathComponent("notes.partial.json"), options: .atomic)
        try Data("{\"needs_refresh\":true}".utf8).write(to: folder.appendingPathComponent("attribution-refresh-needed.json"))
        for name in ["summary.md", "outcomes.json"] { try FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
    }

    /// Static handle on one planted fixture: the tmp `root` to point
    /// `LOKALBOT_STORAGE_ROOT` at, plus the three meetings the tests assert on.
    struct Library {
        let root: URL
        let designReview: Meeting
        let standup: Meeting
        let planning: Meeting

        /// The full meeting set, in display order (newest first).
        var meetings: [Meeting] { [designReview, standup, planning] }

        /// On-disk folder for a planted meeting, mirroring
        /// `Meeting.folderURL(in:)` (`root/relativePath`). Lets a test assert
        /// that a delete actually reached the filesystem, not just the list.
        func folder(for meeting: Meeting) -> URL {
            root.appendingPathComponent(meeting.relativePath, isDirectory: true)
        }

        /// Remove every byte we planted — call from `tearDown` so a leftover
        /// fixture never pollutes the next run's storage root.
        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// Lightweight meeting descriptor — the UI tests assert against these
    /// fields, so all the strings that show up on screen live in one place.
    struct Meeting {
        let id: UUID
        let title: String
        let appName: String
        let startedAt: Date
        let endedAt: Date
        let relativePath: String
        let hasSystemTrack: Bool
        let transcript: [Segment]
        let summaryMarkdown: String
        var calendarParticipants: [Participant] = []

        struct Participant {
            let id: String
            let name: String
            let emailAddress: String
        }

        struct Segment {
            let start: TimeInterval
            let end: TimeInterval
            let speaker: String   // "me" | "them"
            let text: String
        }
    }

    /// Build a fresh tmp library and write every fixture file to disk.
    /// Caller passes the resulting `root` to the app as `LOKALBOT_STORAGE_ROOT`.
    static func plant(includeActivity: Bool = true) throws -> Library {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LokalBotUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("meetings"), withIntermediateDirectories: true)

        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: Date())
        let todayAnchor = calendar.date(byAdding: .hour, value: 12, to: dayStart)
            ?? dayStart.addingTimeInterval(12 * 3_600)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: todayAnchor)
            ?? todayAnchor.addingTimeInterval(-24 * 3_600)

        let designReview = Meeting(
            id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            title: "Design review meeting",
            appName: "Zoom",
            startedAt: todayAnchor.addingTimeInterval(-3_600),          // 11:00 local
            endedAt: todayAnchor.addingTimeInterval(-3_600 + 25 * 60),  // 25-min meeting
            relativePath: relativePath(for: todayAnchor.addingTimeInterval(-3_600),
                                       slug: "design-review-meeting"),
            hasSystemTrack: true,
            transcript: [
                .init(start: 0, end: 12, speaker: "me",
                      text: "Let's decide on the caching layer. I propose Redis because of pub-sub support."),
                .init(start: 12, end: 24, speaker: "them",
                      text: "Agreed on Redis. One open question: do we need cluster mode from day one?"),
                .init(start: 24, end: 35, speaker: "me",
                      text: "I'll draft the eviction policy document by Thursday."),
                .init(start: 35, end: 48, speaker: "them",
                      text: "Please benchmark failover latency before we commit."),
            ],
            summaryMarkdown: """
            ## TL;DR
            The team picked Redis for the caching layer and deferred cluster mode pending a failover benchmark.

            ## Decisions
            - Adopt Redis for caching (pub-sub support won the comparison).

            ## Action items
            - [ ] Draft the eviction policy document by Thursday (Me).
            - [ ] Benchmark failover latency before committing to cluster mode (Them).
            """,
            calendarParticipants: [
                .init(id: "fixture-ana", name: "Ana Petrović",
                      emailAddress: "ana@example.com"),
                .init(id: "fixture-marko", name: "Marko Marković",
                      emailAddress: "marko@example.com"),
            ])

        let standup = Meeting(
            id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
            title: "Engineering standup",
            appName: "Slack",
            startedAt: todayAnchor.addingTimeInterval(-7_200),          // 10:00 local
            endedAt: todayAnchor.addingTimeInterval(-7_200 + 15 * 60),  // 15-min standup
            relativePath: relativePath(for: todayAnchor.addingTimeInterval(-7_200),
                                       slug: "engineering-standup"),
            hasSystemTrack: false,
            transcript: [
                .init(start: 0, end: 8, speaker: "me",
                      text: "Quick standup. I'm picking up the Postgres migration today."),
                .init(start: 8, end: 18, speaker: "me",
                      text: "Blocker on the index rebuild — needs review from the data team."),
            ],
            summaryMarkdown: """
            ## TL;DR
            Postgres migration kick-off; index rebuild blocked on data-team review.

            ## Action items
            - [ ] Unblock the index rebuild with the data team (Me).
            """)

        let planning = Meeting(
            id: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
            title: "Q3 roadmap planning",
            appName: "Manual",
            startedAt: yesterday,
            endedAt: yesterday.addingTimeInterval(35 * 60),     // 35-min planning
            relativePath: relativePath(for: yesterday, slug: "q3-roadmap-planning"),
            hasSystemTrack: false,
            transcript: [
                .init(start: 0, end: 20, speaker: "me",
                      text: "We need to lock down the Q3 roadmap. Onboarding is the top priority for new accounts."),
                .init(start: 20, end: 40, speaker: "me",
                      text: "Second priority is reliability work — the alerting backlog has grown three quarters in a row."),
            ],
            summaryMarkdown: """
            ## TL;DR
            Q3 priorities are onboarding (top) and reliability (alerting backlog).

            ## Decisions
            - Onboarding ranks above reliability for Q3.
            """)

        for meeting in [designReview, standup, planning] {
            try write(meeting, under: root)
        }
        try seedDayDigests(under: root, today: todayAnchor, previousDay: yesterday)
        if includeActivity {
            seedActivity(under: root, today: todayAnchor)
        }
        return Library(root: root, designReview: designReview,
                       standup: standup, planning: planning)
    }

    /// Seed a few `activity_blocks` for *today* straight into the shared
    /// SQLite db so the Timeline screen has real data to render. The app
    /// creates this table `IF NOT EXISTS` at launch, so a pre-created one is
    /// compatible. Uses the SQLite C API directly — the bundle stays
    /// decoupled from the app target, mirroring how the rest of the fixture
    /// writes raw on-disk shape.
    private static func seedActivity(under root: URL, today: Date) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let dbPath = root.appendingPathComponent("lokalbotv3.sqlite").path
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }
        sqlite3_exec(db, """
            CREATE TABLE IF NOT EXISTS activity_blocks (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                app TEXT NOT NULL, title TEXT NOT NULL,
                start REAL NOT NULL, end REAL NOT NULL);
            """, nil, nil, nil)
        let dayStart = Calendar.current.startOfDay(for: today).timeIntervalSince1970
        // (app, title, startMinuteOfDay, endMinuteOfDay) — anchored to today.
        let rows: [(String, String, Double, Double)] = [
            ("Xcode", "TimelineView.swift", 9 * 60, 10 * 60 + 30),
            ("Safari", "Pull request #42", 10 * 60 + 30, 11 * 60 + 15),
            ("Slack", "#engineering", 11 * 60 + 15, 11 * 60 + 25),
        ]
        for (appName, title, startMin, endMin) in rows {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db,
                "INSERT INTO activity_blocks (app, title, start, end) VALUES (?,?,?,?);",
                -1, &stmt, nil) == SQLITE_OK else { continue }
            sqlite3_bind_text(stmt, 1, appName, -1, transient)
            sqlite3_bind_text(stmt, 2, title, -1, transient)
            sqlite3_bind_double(stmt, 3, dayStart + startMin * 60)
            sqlite3_bind_double(stmt, 4, dayStart + endMin * 60)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    /// Give adjacent Timeline days unmistakably different persisted digests.
    /// The date-change UI test can then prove that the detail column refreshed
    /// the journal document, not merely the track or its date picker.
    private static func seedDayDigests(under root: URL, today: Date,
                                       previousDay: Date) throws {
        let journal = root.appendingPathComponent("journal", isDirectory: true)
        try FileManager.default.createDirectory(at: journal,
                                                withIntermediateDirectories: true)
        for (day, marker) in [(today, todayDigestMarker),
                              (previousDay, previousDayDigestMarker)] {
            let digest = """
                ## Day summary

                ### At a glance
                - \(marker)
                - Verified the synthetic Timeline state.

                ### Focus blocks
                - **09:00–10:30 · Fixture implementation** — User updated the Timeline UI. [screen:4242]

                ## Meetings

                _None._

                ## Time allocation

                | App | Tracked time |
                | --- | ---: |
                | Xcode | 1h 30m |

                ## Full activity log

                - **09:00–10:30** — **Xcode** — TimelineView.swift
                  - [screen:4242], 09:30: Updated the Timeline UI.
                """
            try digest.write(
                to: journal.appendingPathComponent("\(dayKey(for: day)).md"),
                atomically: true,
                encoding: .utf8)
        }
    }

    private static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d",
                      parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: - Helpers

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func relativePath(for date: Date, slug: String) -> String {
        let cal = Calendar.current
        let year = cal.component(.year, from: date)
        let month = String(format: "%02d", cal.component(.month, from: date))
        let day = String(format: "%02d", cal.component(.day, from: date))
        return "meetings/\(year)/\(month)/\(day)-\(slug)"
    }

    private static func write(_ meeting: Meeting, under root: URL) throws {
        let folder = root.appendingPathComponent(meeting.relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // meta.json — must round-trip through StorageManager.loadMeetings()
        let participantNames = meeting.calendarParticipants
            .map { jsonString($0.name) }
            .joined(separator: ", ")
        let participantIdentities = meeting.calendarParticipants.map { participant in
            """
              {
                "emailAddress" : \(jsonString(participant.emailAddress)),
                "id" : \(jsonString(participant.id)),
                "name" : \(jsonString(participant.name))
              }
            """
        }.joined(separator: ",\n")
        let calendarMetadata = meeting.calendarParticipants.isEmpty ? "" : """
        ,
          "participantNameHints" : [\(participantNames)],
          "calendarParticipantIdentities" : [
        \(participantIdentities)
          ]
        """
        let meta = """
        {
          "appName" : "\(meeting.appName)",
          "endedAt" : "\(isoFormatter.string(from: meeting.endedAt))",
          "hasSystemTrack" : \(meeting.hasSystemTrack ? "true" : "false"),
          "id" : "\(meeting.id.uuidString)",
          "relativePath" : "\(meeting.relativePath)",
          "startedAt" : "\(isoFormatter.string(from: meeting.startedAt))",
          "title" : "\(meeting.title)"\(calendarMetadata)
        }
        """
        try meta.write(to: folder.appendingPathComponent("meta.json"),
                       atomically: true, encoding: .utf8)

        // transcript.json — consumed by SearchIndex.reindex and the meeting workspace.
        let segments = meeting.transcript.map { segment -> String in
            """
              {
                "start" : \(segment.start),
                "end" : \(segment.end),
                "speaker" : "\(segment.speaker)",
                "text" : \(jsonString(segment.text))
              }
            """
        }.joined(separator: ",\n")
        let transcriptJSON = """
        {
          "engine" : "synthetic-fixture",
          "segments" : [
        \(segments)
          ]
        }
        """
        try transcriptJSON.write(to: folder.appendingPathComponent("transcript.json"),
                                 atomically: true, encoding: .utf8)

        // Human-readable transcript.md (mirrors ProcessingPipeline.write).
        let markdown = meeting.transcript.map { segment in
            "**[\(stamp(segment.start))] \(segment.speaker.capitalized):** \(segment.text)"
        }.joined(separator: "\n\n")
        try markdown.write(to: folder.appendingPathComponent("transcript.md"),
                           atomically: true, encoding: .utf8)

        // summary.md — rendered by MarkdownText in the Summary tab.
        try meeting.summaryMarkdown.write(to: folder.appendingPathComponent("summary.md"),
                                          atomically: true, encoding: .utf8)

        // A short readable recovery track makes the real meeting player part
        // of the UI fixture without reaching for microphone or system audio.
        try writeAudioFixture(to: folder.appendingPathComponent("mic.live.caf"))
        if meeting.hasSystemTrack { try writeAudioFixture(to: folder.appendingPathComponent("system.live.caf")) }

        // Grounded outcome fixtures drive the redesigned Today, Timeline,
        // and full Meetings follow-through workspace.
        try outcomeJSON(for: meeting).write(
            to: folder.appendingPathComponent("outcomes.json"),
            atomically: true,
            encoding: .utf8)
    }

    private static func writeAudioFixture(to url: URL) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000 * 60) else {
            throw NSError(
                domain: "LokalBotUITests.SyntheticFixture",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not create audio fixture format."])
        }
        buffer.frameLength = buffer.frameCapacity
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private static func outcomeJSON(for meeting: Meeting) -> String {
        struct Action {
            let id: String
            let text: String
            let owner: String
            let due: String?
            let segment: Int
        }
        struct Decision {
            let id: String
            let text: String
            let segment: Int
        }

        let actions: [Action]
        let decisions: [Decision]
        let questions: [String]
        switch meeting.id.uuidString.lowercased().prefix(8) {
        case "11111111":
            actions = [
                .init(id: "fixture-action-design-1",
                      text: "Draft the eviction policy document", owner: "Me",
                      due: "Thursday", segment: 2),
                .init(id: "fixture-action-design-2",
                      text: "Benchmark failover latency before committing to cluster mode",
                      owner: "Them", due: nil, segment: 3),
            ]
            decisions = [
                .init(id: "fixture-decision-design-1",
                      text: "Adopt Redis for caching", segment: 1),
            ]
            questions = ["Do we need cluster mode from day one?"]
        case "22222222":
            actions = [
                .init(id: "fixture-action-standup-1",
                      text: "Unblock the index rebuild with the data team",
                      owner: "Me", due: nil, segment: 1),
            ]
            decisions = []
            questions = []
        default:
            actions = []
            decisions = [
                .init(id: "fixture-decision-roadmap-1",
                      text: "Onboarding ranks above reliability for Q3", segment: 0),
            ]
            questions = []
        }

        let actionJSON = actions.map { action in
            let due = action.due.map { ",\n        \"due\" : \(jsonString($0))" } ?? ""
            return """
              {
                "id" : "\(action.id)",
                "schemaVersion" : 2,
                "text" : \(jsonString(action.text)),
                "owner" : "\(action.owner)",
                "isForUser" : \(action.owner == "Me" ? "true" : "false")\(due),
                "citations" : [\(citationJSON(for: meeting, segment: action.segment))]
              }
            """
        }.joined(separator: ",\n")
        let decisionJSON = decisions.map { decision in
            """
              {
                "id" : "\(decision.id)",
                "schemaVersion" : 2,
                "text" : \(jsonString(decision.text)),
                "citations" : [\(citationJSON(for: meeting, segment: decision.segment))]
              }
            """
        }.joined(separator: ",\n")
        let questionJSON = questions.map(jsonString).joined(separator: ", ")
        return """
        {
          "schemaVersion" : 2,
          "actionItems" : [
        \(actionJSON)
          ],
          "decisionRecords" : [
        \(decisionJSON)
          ],
          "openQuestions" : [\(questionJSON)]
        }
        """
    }

    private static func citationJSON(for meeting: Meeting, segment index: Int) -> String {
        let segment = meeting.transcript[index]
        let segmentID = String(
            format: "segment-%04d-%010lld-%010lld",
            index,
            Int64((segment.start * 1_000).rounded()),
            Int64((segment.end * 1_000).rounded()))
        return """

                {
                  "meetingID" : "\(meeting.id.uuidString)",
                  "segmentID" : "\(segmentID)",
                  "start" : \(segment.start),
                  "end" : \(segment.end),
                  "speaker" : "\(segment.speaker)",
                  "excerpt" : \(jsonString(segment.text))
                }
        """
    }

    /// Minimal JSON-string escaper for the few control characters we ever emit.
    private static func jsonString(_ raw: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(raw.count + 2)
        escaped.append("\"")
        for scalar in raw.unicodeScalars {
            switch scalar {
            case "\\": escaped.append("\\\\")
            case "\"": escaped.append("\\\"")
            case "\n": escaped.append("\\n")
            case "\r": escaped.append("\\r")
            case "\t": escaped.append("\\t")
            default:
                if scalar.value < 0x20 {
                    escaped.append(String(format: "\\u%04x", scalar.value))
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        escaped.append("\"")
        return escaped
    }

    private static func stamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d:%02d", total / 3_600, (total % 3_600) / 60, total % 60)
    }
}
