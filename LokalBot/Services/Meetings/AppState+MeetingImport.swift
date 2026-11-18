import Foundation

/// What importing from another app would add, counted without writing
/// anything. The approval card and `lokalbot-cli import --dry-run` show it.
struct ExternalImportPlan: Equatable, Sendable {
    var source: ExternalMeetingSource
    var paths: [String]
    var found = 0
    var newMeetings = 0
    var alreadyImported = 0
    /// New meetings that bring a recording without a transcript, which
    /// LokalBot transcribes on this computer.
    var toTranscribe = 0
    var earliest: Date?
    var latest: Date?
    var problems: [ExternalImportScan.Problem] = []

    init(source: ExternalMeetingSource, paths: [String], scan: ExternalImportScan,
         importedKeys: Set<String>, libraryIDs: Set<UUID>) {
        self.source = source
        self.paths = paths
        found = scan.meetings.count
        problems = scan.problems
        for meeting in scan.meetings {
            if ExternalMeetingWriter.isAlreadyImported(meeting, keys: importedKeys, ids: libraryIDs) {
                alreadyImported += 1
                continue
            }
            newMeetings += 1
            if meeting.audioURL != nil, meeting.lines.isEmpty { toTranscribe += 1 }
            if let start = meeting.startedAt {
                earliest = min(earliest ?? start, start)
                latest = max(latest ?? start, start)
            }
        }
    }

    /// The plan as the socket and the approval card report it. Paths and
    /// counts only, never a meeting's contents.
    var json: JSONValue {
        var object: [String: JSONValue] = [
            "source": .string(source.rawValue),
            "title": .string(source.title),
            "paths": .array(paths.map(JSONValue.string)),
            "found": .number(Double(found)),
            "newMeetings": .number(Double(newMeetings)),
            "alreadyImported": .number(Double(alreadyImported)),
            "toTranscribe": .number(Double(toTranscribe)),
            "problems": .array(problems.map { ["path": .string($0.path), "reason": .string($0.reason)] }),
        ]
        let formatter = ISO8601DateFormatter()
        if let earliest { object["earliest"] = .string(formatter.string(from: earliest)) }
        if let latest { object["latest"] = .string(formatter.string(from: latest)) }
        return .object(object)
    }
}

/// How an import went, for the person and the log.
struct ExternalImportSummary: Equatable {
    var source: ExternalMeetingSource
    var imported: [UUID] = []
    var alreadyImported = 0
    var transcribing = 0
    var failures: [String] = []
    var problems: [ExternalImportScan.Problem] = []

    /// What the person sees when the import ends, or nil when it simply
    /// worked and the new meetings speak for themselves.
    var message: String? {
        var parts: [String] = []
        if imported.isEmpty {
            parts.append(alreadyImported > 0
                ? "Everything in this \(source.title) export is already in your library."
                : "LokalBot found no \(source.title) meetings there. \(source.exportHint)")
        }
        if !failures.isEmpty {
            parts.append("\(failures.count) \(source.title) meetings couldn't be imported:\n" + failures.prefix(5).joined(separator: "\n"))
        }
        if !problems.isEmpty {
            parts.append("Some files couldn't be read:\n" + problems.prefix(5).map { "\($0.path): \($0.reason)" }.joined(separator: "\n"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }
}

extension AppState {
    /// Reads the files off the main thread and counts what an import would
    /// add. Writes nothing.
    func planExternalImport(_ source: ExternalMeetingSource, urls: [URL]) async -> ExternalImportPlan {
        let result = await Task.detached(priority: .userInitiated) {
            ExternalMeetingReaders.scan(source, urls: urls)
        }.value
        defer { result.cleanup() }
        let library = storage.loadMeetings(includeMergedSources: true)
        return ExternalImportPlan(
            source: source, paths: urls.map(\.path), scan: result.scan,
            importedKeys: ExternalMeetingWriter.importedKeys(in: library),
            libraryIDs: Set(library.map(\.id)))
    }

    /// Imports every meeting in `urls` that isn't in the library yet. The
    /// person chose the files, or approved the request, so nothing asks
    /// again. Imports run one after another, after any recording imports.
    func importExternalMeetings(_ source: ExternalMeetingSource, urls: [URL]) {
        guard !urls.isEmpty else { return }
        let label = "\(source.title) meetings"
        navSection = .meetings
        beginRecordingImport(named: label) { app in
            let summary = await app.runExternalImport(source, urls: urls)
            if let first = summary.imported.first { app.selectedMeetingIDs = [first] }
            if let message = summary.message { app.lastError = message }
        }
    }

    /// The import itself, returning what happened. Meetings already in the
    /// library, by their source id or LokalBot id, are skipped.
    @discardableResult
    func runExternalImport(_ source: ExternalMeetingSource, urls: [URL], now: Date = Date()) async -> ExternalImportSummary {
        let result = await Task.detached(priority: .userInitiated) {
            ExternalMeetingReaders.scan(source, urls: urls)
        }.value
        defer { result.cleanup() }
        var summary = ExternalImportSummary(source: source, problems: result.scan.problems)
        let library = storage.loadMeetings(includeMergedSources: true)
        var keys = ExternalMeetingWriter.importedKeys(in: library)
        var ids = Set(library.map(\.id))
        var written: [ExternalMeetingWriter.Result] = []
        let ordered = result.scan.meetings.sorted { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
        for external in ordered {
            guard !ExternalMeetingWriter.isAlreadyImported(external, keys: keys, ids: ids) else {
                summary.alreadyImported += 1
                continue
            }
            do {
                let outcome = try await ExternalMeetingWriter.write(external, storage: storage, now: now)
                keys.insert(external.importKey)
                ids.insert(outcome.meeting.id)
                written.append(outcome)
            } catch {
                summary.failures.append("\(ExternalMeetingWriter.title(for: external)): \(error.localizedDescription)")
            }
        }
        // One list update for the whole batch rather than one per meeting.
        appendImportedMeetings(written.map(\.meeting))
        for outcome in written {
            summary.imported.append(outcome.meeting.id)
            if outcome.needsTranscription {
                summary.transcribing += 1
                reprocess(outcome.meeting, transcribe: true, summarize: settings.autoSummarize)
            } else {
                meetingArtifactsWritten(outcome.meeting)
            }
        }
        // Counts only: titles and paths stay out of the log.
        lokalbotLog("external import source=\(source.rawValue) imported=\(summary.imported.count) "
            + "skipped=\(summary.alreadyImported) transcribing=\(summary.transcribing) "
            + "failed=\(summary.failures.count) unreadable=\(summary.problems.count)")
        return summary
    }
}
