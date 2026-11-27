import Foundation

enum SampleMeeting {
    static let precomputedEngine = "sample-precomputed"

    struct Recording: Equatable, Sendable {
        let id: String
        let language: String
        let title: String
        let fileName: String
    }

    struct ReferenceTranscript: Codable, Equatable, Sendable {
        struct Turn: Codable, Equatable, Sendable {
            let id: String
            let speaker: String
            let name: String
            let start: TimeInterval
            let end: TimeInterval
            let text: String
        }

        let sampleID: String
        let language: String
        let title: String
        let duration: TimeInterval
        let turns: [Turn]
    }

    struct ExpectedContent: Codable, Equatable, Sendable {
        struct Entity: Codable, Equatable, Sendable {
            let kind: String
            let label: String
            let turn: String
            let any: [String]
        }

        struct DecisionEntry: Codable, Equatable, Sendable {
            let text: String
            let turns: [String]
        }

        struct ChangedDecision: Codable, Equatable, Sendable {
            let before: String
            let beforeTurns: [String]
            let after: String
            let afterTurns: [String]
        }

        struct AskEntry: Codable, Equatable, Sendable {
            let question: String
            let answerPoints: [String]
            let citesTurns: [String]
        }

        let sampleID: String
        let language: String
        let speakers: Int
        let entities: [Entity]
        let decision: DecisionEntry
        let changedDecision: ChangedDecision
        let openQuestion: DecisionEntry
        let ask: AskEntry
    }

    enum HydrationError: LocalizedError {
        case missingResources(String)

        var errorDescription: String? {
            switch self {
            case .missingResources(let id):
                "The sample meeting resources for \(id) are missing from this copy of LokalBot."
            }
        }
    }

    static let english = Recording(
        id: "orders-api/en", language: "en",
        title: "Sample: Orders API delivery window", fileName: "orders-api.en.m4a")

    static let recordings = [
        english,
        Recording(id: "orders-api/de", language: "de",
                  title: "Beispiel: delivery window in der Orders API", fileName: "orders-api.de.m4a"),
        Recording(id: "orders-api/zh", language: "zh",
                  title: "示例：Orders API 的 delivery window", fileName: "orders-api.zh.m4a"),
        Recording(id: "orders-api/sr-Latn", language: "sr-Latn",
                  title: "Primer: delivery window u Orders API-ju", fileName: "orders-api.sr-Latn.m4a"),
    ]

    static let question = "Is the delivery window field required in the Orders API response?"

    static func recording(for language: String) -> Recording {
        let base = language.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? language
        return recordings.first { $0.language.caseInsensitiveCompare(language) == .orderedSame }
            ?? recordings.first { $0.language.caseInsensitiveCompare(base) == .orderedSame }
            ?? english
    }

    static func recording(forSampleID sampleID: String) -> Recording? {
        recordings.first { $0.id == sampleID }
    }

    static func audioURL(for recording: Recording, bundle: Bundle = .main) -> URL? {
        let url = URL(fileURLWithPath: recording.fileName)
        return bundle.url(forResource: url.deletingPathExtension().lastPathComponent,
                          withExtension: url.pathExtension, subdirectory: "SampleMeeting")
    }

    static func referenceJSONURL(for recording: Recording, bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: "reference.\(recording.language)",
                   withExtension: "json", subdirectory: "SampleMeeting")
    }

    static func referenceMarkdownURL(for recording: Recording, bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: "reference.\(recording.language)",
                   withExtension: "md", subdirectory: "SampleMeeting")
    }

    static func expectedJSONURL(for recording: Recording, bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: "expected.\(recording.language)",
                   withExtension: "json", subdirectory: "SampleMeeting")
    }

    static func loadReference(for recording: Recording, bundle: Bundle = .main) -> ReferenceTranscript? {
        guard let url = referenceJSONURL(for: recording, bundle: bundle),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ReferenceTranscript.self, from: data)
    }

    static func loadExpected(for recording: Recording, bundle: Bundle = .main) -> ExpectedContent? {
        guard let url = expectedJSONURL(for: recording, bundle: bundle),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ExpectedContent.self, from: data)
    }

    static func hydratePrecomputed(
        recording: Recording,
        storage: StorageManager,
        now: Date = Date(),
        bundle: Bundle = .main
    ) throws -> Meeting {
        guard let reference = loadReference(for: recording, bundle: bundle),
              let expected = loadExpected(for: recording, bundle: bundle) else {
            throw HydrationError.missingResources(recording.id)
        }
        let duration = max(reference.duration, reference.turns.last?.end ?? 210)
        let startedAt = now.addingTimeInterval(-duration)
        let relativePath = try storage.reserveMeetingFolder(title: reference.title, startedAt: startedAt)
        let meetingID = UUID()
        var meeting = Meeting(
            id: meetingID,
            title: reference.title,
            appName: MeetingImportService.appName,
            startedAt: startedAt,
            endedAt: now,
            relativePath: relativePath)
        meeting.recordedDuration = duration
        meeting.importedFileNames = [recording.fileName]
        meeting.sampleID = recording.id

        let folder = meeting.folderURL(in: storage)
        do {
            if let audioURL = audioURL(for: recording, bundle: bundle) {
                let destination = MeetingAudioFiles.primaryURL(for: .system, in: folder)
                try FileManager.default.copyItem(at: audioURL, to: destination)
                meeting.hasSystemTrack = true
            }
            try storage.saveMeta(meeting)

            let transcript = buildTranscript(from: reference)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(transcript).write(
                to: folder.appendingPathComponent("transcript.json"), options: .atomic)

            let outcomes = buildOutcomes(meetingID: meetingID, transcript: transcript, reference: reference, expected: expected)
            try outcomes.write(to: folder)

            let summary = buildSummaryMarkdown(reference: reference, expected: expected, duration: duration)
            try Data(summary.utf8).write(
                to: folder.appendingPathComponent("summary.md"), options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return meeting
    }

    static func askQuestion(
        for meeting: Meeting,
        language: AppLanguage,
        bundle: Bundle = .main
    ) -> String {
        if let sampleID = meeting.sampleID,
           let recording = recording(forSampleID: sampleID),
           let expected = loadExpected(for: recording, bundle: bundle) {
            return expected.ask.question
        }
        return language.localized(question)
    }

    static func precomputedAskAnswer(
        for meeting: Meeting,
        question: String,
        bundle: Bundle = .main
    ) -> String? {
        guard let sampleID = meeting.sampleID,
              let recording = recording(forSampleID: sampleID),
              let reference = loadReference(for: recording, bundle: bundle),
              let expected = loadExpected(for: recording, bundle: bundle) else { return nil }
        let shortID = SessionLookup.shortID(meeting.id)
        let turnsByID = Dictionary(uniqueKeysWithValues: reference.turns.map { ($0.id, $0) })

        func markers(for turnIDs: [String]) -> String {
            turnIDs.compactMap { id -> String? in
                guard let turn = turnsByID[id] else { return nil }
                return "[meeting:\(shortID)@\(Transcript.stamp(turn.start))]"
            }.joined(separator: " ")
        }

        let lowered = question.lowercased()
        let isBackfillQuestion = lowered.contains("backfill")
            || lowered.contains("old order")
            || lowered.contains("回填")
            || lowered.contains("bestellungen")
            || lowered.contains("porudžbin")
        let isActionQuestion = lowered.contains("action")
            || lowered.contains("friday")
            || lowered.contains("changelog")
            || lowered.contains("priya")
            || lowered.contains("prija")
            || lowered.contains("freitag")
            || lowered.contains("周五")
            || lowered.contains("petak")

        if isBackfillQuestion {
            let cite = markers(for: expected.openQuestion.turns)
            return "\(expected.openQuestion.text) \(cite)".trimmingCharacters(in: .whitespaces)
        }
        if isActionQuestion {
            let cite = markers(for: expected.decision.turns)
            return "\(expected.decision.text) \(cite)".trimmingCharacters(in: .whitespaces)
        }

        let primaryCite = markers(for: expected.ask.citesTurns)
        let lines = expected.ask.answerPoints.enumerated().map { index, point in
            if index == 0, !primaryCite.isEmpty {
                return "\(point) \(primaryCite)"
            }
            if index == expected.ask.answerPoints.count - 1 {
                let beforeCite = markers(for: expected.changedDecision.beforeTurns)
                return beforeCite.isEmpty ? "- \(point)" : "- \(point) \(beforeCite)"
            }
            return "- \(point)"
        }
        return lines.joined(separator: "\n")
    }

    private static func buildTranscript(from reference: ReferenceTranscript) -> Transcript {
        var aliases: [String: String] = [:]
        let segments = reference.turns.map { turn -> Transcript.Segment in
            if aliases[turn.speaker] == nil {
                aliases[turn.speaker] = turn.name
            }
            return Transcript.Segment(
                start: turn.start,
                end: turn.end,
                speaker: turn.speaker,
                text: turn.text,
                timingPrecision: .span)
        }
        return Transcript(segments: segments, engine: precomputedEngine, speakerAliases: aliases)
    }

    private static func buildOutcomes(
        meetingID: UUID,
        transcript: Transcript,
        reference: ReferenceTranscript,
        expected: ExpectedContent
    ) -> MeetingOutcomes {
        let indexByTurnID = Dictionary(uniqueKeysWithValues: reference.turns.enumerated().map { ($0.element.id, $0.offset) })

        func citations(for turnIDs: [String]) -> [OutcomeSourceCitation] {
            turnIDs.compactMap { turnID in
                guard let idx = indexByTurnID[turnID] else { return nil }
                let turn = reference.turns[idx]
                return OutcomeSourceCitation(
                    meetingID: meetingID,
                    segmentID: transcript.segmentID(at: idx),
                    start: turn.start,
                    end: turn.end,
                    speaker: turn.name,
                    excerpt: turn.text)
            }
        }

        let decisions = [
            MeetingOutcomes.Decision(
                text: expected.changedDecision.after,
                citations: citations(for: expected.changedDecision.afterTurns)),
            MeetingOutcomes.Decision(
                text: expected.decision.text,
                citations: citations(for: expected.decision.turns)),
        ]

        let priyaName = entityName(atTurn: "t06", in: expected) ?? "Priya"
        let danielName = entityName(atTurn: "t02", in: expected) ?? "Daniel"
        let mayaName = entityName(atTurn: "t03", in: expected) ?? "Maya"
        let fridayDue = entityDue(atTurn: "t23", in: expected)

        let decisionParts = expected.decision.text
            .split(whereSeparator: { $0 == ";" || $0 == "；" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var actionItems: [MeetingOutcomes.ActionItem] = []
        if let firstPart = decisionParts.first {
            actionItems.append(MeetingOutcomes.ActionItem(
                text: firstPart,
                owner: priyaName,
                isForUser: false,
                importance: 4,
                citations: citations(for: ["t22"])))
        }
        if decisionParts.count > 1 {
            actionItems.append(MeetingOutcomes.ActionItem(
                text: decisionParts[1],
                owner: danielName,
                due: fridayDue,
                isForUser: false,
                importance: 5,
                citations: citations(for: ["t22", "t23"])))
        }
        if let t27 = reference.turns.first(where: { $0.id == "t27" }) {
            actionItems.append(MeetingOutcomes.ActionItem(
                text: t27.text,
                owner: mayaName,
                isForUser: false,
                importance: 3,
                citations: citations(for: ["t27"])))
        }

        var outcomes = MeetingOutcomes(
            actionItems: actionItems,
            decisions: [],
            openQuestions: [expected.openQuestion.text])
        outcomes.decisionRecords = decisions
        outcomes.transcriptRevision = transcript.evidenceRevision
        return outcomes
    }

    private static func entityName(atTurn turn: String, in expected: ExpectedContent) -> String? {
        expected.entities.first { $0.kind == "name" && $0.turn == turn }?.label
    }

    private static func entityDue(atTurn turn: String, in expected: ExpectedContent) -> String? {
        guard let label = expected.entities.first(where: { $0.kind == "date" && $0.turn == turn })?.label else {
            return nil
        }
        return label.split(whereSeparator: { $0 == "(" || $0 == "（" }).first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func buildSummaryMarkdown(
        reference: ReferenceTranscript,
        expected: ExpectedContent,
        duration: TimeInterval
    ) -> String {
        let minutes = max(1, Int(duration / 60))
        return """
        # \(reference.title)
        **Duration:** \(minutes) min · **App:** Sample

        ## TL;DR
        - \(expected.changedDecision.after)
        - \(expected.decision.text)
        - \(expected.openQuestion.text)

        ## Decisions
        - \(expected.changedDecision.after)
        - \(expected.decision.text)

        ## Earlier plan replaced
        - \(expected.changedDecision.before)

        ## Open questions
        - \(expected.openQuestion.text)
        """
    }
}
