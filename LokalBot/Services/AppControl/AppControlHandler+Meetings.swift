import Foundation

extension AppControlHandler {
    func reprocessMeeting(_ params: [String: JSONValue], caller: String, in app: AppState) throws -> JSONValue {
        let meeting = try Self.meeting(params, in: app)
        let transcribe = try Self.flag("transcribe", in: params, default: false)
        let summarize = try Self.flag("summarize", in: params, default: true)
        guard transcribe || summarize else {
            throw AppControlError.invalidRequest("Ask meetings.reprocess to transcribe, summarize, or both.")
        }
        let folder = meeting.folderURL(in: app.storage)
        if !transcribe, !FileManager.default.fileExists(atPath: folder.appendingPathComponent("transcript.json").path) {
            throw AppControlError.invalidRequest(
                "\(meeting.title) has no transcript to summarize yet. Pass --transcribe to transcribe it first.")
        }
        switch app.reprocess(meeting, transcribe: transcribe, summarize: summarize) {
        case .enqueued, .coalesced, .updatedActive:
            lokalbotLog("app-control reprocess meeting=\(meeting.id) transcribe=\(transcribe) "
                + "summarize=\(summarize) caller=\(caller)")
            return Self.processing(meeting, stage: app.pipeline.stages[meeting.id], folder: folder)
        case .alreadyProcessing:
            throw AppControlError.alreadyProcessing
        case .persistenceFailed:
            throw AppControlError.invalidRequest("LokalBot could not save the processing request.")
        case .revoked:
            throw AppControlError.invalidRequest("This meeting is being removed and can no longer be processed.")
        }
    }

    func processingState(_ params: [String: JSONValue], in app: AppState) throws -> JSONValue {
        let meeting = try Self.meeting(params, in: app)
        return Self.processing(meeting, stage: app.pipeline.stages[meeting.id], folder: meeting.folderURL(in: app.storage))
    }

    static func meeting(_ params: [String: JSONValue], in app: AppState) throws -> Meeting {
        guard let id = params["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            throw AppControlError.invalidRequest("Name the meeting in \"id\": an ID from `lokalbot-cli list`, or latest.")
        }
        let meetings = app.libraryReady
            ? app.meetings.filter { !$0.isMergedSource }
            : try SessionLookup.loadAllMeetings(root: app.storage.rootURL)
        guard let meeting = try SessionLookup.find(id: id, in: meetings) else {
            throw AppControlError.unknownMeeting(id)
        }
        return meeting
    }

    static func processing(_ meeting: Meeting, stage: ProcessingPipeline.Stage?, folder: URL) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(SessionLookup.shortID(meeting.id)),
            "title": .string(meeting.title),
            "state": .string(stage.map(state) ?? "idle"),
        ]
        if let stage { object["message"] = .string(stage.label) }
        let summary = folder.appendingPathComponent("summary.md")
        if let modified = (try? summary.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
            object["notesSavedAt"] = .string(ISO8601DateFormatter().string(from: modified))
        }
        return .object(object)
    }

    static func state(_ stage: ProcessingPipeline.Stage) -> String {
        switch stage {
        case .queued: "queued"
        case .waitingForModels: "waitingForModels"
        case .preparingTranscriptionModel, .preparingDiarizationModel, .preparingSummaryModel: "preparing"
        case .transcribing: "transcribing"
        case .diarizing: "identifyingSpeakers"
        case .summarizing: "summarizing"
        case .failed: "failed"
        }
    }

    private static func flag(_ key: String, in params: [String: JSONValue], default value: Bool) throws -> Bool {
        switch params[key] {
        case nil, .null?: return value
        case .bool(let flag)?: return flag
        default: throw AppControlError.invalidRequest("\"\(key)\" must be true or false.")
        }
    }
}
