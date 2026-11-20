import CryptoKit
import Foundation

enum ExternalMeetingWriter {
    static let importedNotesFileName = "imported-notes.md"

    struct Result: Equatable {
        var meeting: Meeting
        var needsTranscription: Bool
    }

    static func meetingID(for external: ExternalMeeting) -> UUID {
        let digest = Array(SHA256.hash(data: Data("lokalbot-import/\(external.importKey)".utf8)))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static func isAlreadyImported(_ external: ExternalMeeting, keys: Set<String>, ids: Set<UUID>) -> Bool {
        keys.contains(external.importKey) || ids.contains(meetingID(for: external))
    }

    static func importedKeys(in meetings: [Meeting]) -> Set<String> {
        Set(meetings.compactMap { $0.importSource?.key })
    }

    static func write(_ external: ExternalMeeting, storage: StorageManager, now: Date = Date()) async throws -> Result {
        let id = meetingID(for: external)
        let title = Self.title(for: external)
        let transcript = Self.transcript(for: external)
        let notes = Self.notesMarkdown(for: external)
        var meeting: Meeting
        if let audio = external.audioURL {
            meeting = try await MeetingImportService.importExternalRecording(
                from: audio, id: id, title: title, appName: external.source.title,
                startedAt: external.startedAt, track: recordingTrack(for: external.source),
                storage: storage, now: now)
        } else {
            let duration = external.duration ?? transcript?.segments.map(\.end).max() ?? 0
            let start = min(external.startedAt ?? fallbackStart(for: external, now: now),
                            now.addingTimeInterval(-duration))
            let relativePath = try storage.reserveMeetingFolder(title: title, startedAt: start)
            meeting = Meeting(id: id, title: title, appName: external.source.title, startedAt: start,
                              endedAt: start.addingTimeInterval(duration), relativePath: relativePath)
            meeting.importedFileNames = [external.origin.lastPathComponent]
        }
        meeting.importSource = .init(app: external.source.rawValue, id: external.sourceID, importedAt: now)
        let participants = external.participants
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !participants.isEmpty { meeting.participantNameHints = participants }

        let folder = meeting.folderURL(in: storage)
        do {
            if let transcript {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(transcript).write(to: folder.appendingPathComponent("transcript.json"), options: .atomic)
                try Data(transcript.markdown.utf8).write(to: folder.appendingPathComponent("transcript.md"), options: .atomic)
            }
            if let notes {
                try Data(notes.utf8).write(to: folder.appendingPathComponent("summary.md"), options: .atomic)
                try Data(notes.utf8).write(to: folder.appendingPathComponent(importedNotesFileName), options: .atomic)
            }
            try storage.saveMeta(meeting)
        } catch {
            if external.audioURL == nil { try? FileManager.default.removeItem(at: folder) }
            throw error
        }
        return Result(meeting: meeting, needsTranscription: external.audioURL != nil && transcript == nil)
    }

    static func recordingTrack(for source: ExternalMeetingSource) -> MeetingAudioFiles.Track {
        source == .voiceMemos ? .mic : .system
    }

    static func title(for external: ExternalMeeting) -> String {
        let cleaned = external.title.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "\(external.source.title) meeting" : cleaned
    }

    private static func fallbackStart(for external: ExternalMeeting, now: Date) -> Date {
        let modified = (try? external.origin.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        return min(modified ?? now, now)
    }

    static func transcript(for external: ExternalMeeting) -> Transcript? {
        let lines = external.lines.compactMap { line -> ExternalMeeting.Line? in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            var cleaned = line
            cleaned.text = text
            return cleaned
        }
        guard !lines.isEmpty else { return nil }
        var labels: [String: String] = [:]
        var aliases: [String: String] = [:]
        var segments: [Transcript.Segment] = []
        var cursor: TimeInterval = 0
        for (index, line) in lines.enumerated() {
            let label: String
            if line.isMe {
                label = "me"
            } else if let name = line.speaker?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                let key = name.lowercased()
                if let existing = labels[key] {
                    label = existing
                } else {
                    label = "them \(labels.count + 1)"
                    labels[key] = label
                    aliases[label] = name
                }
            } else {
                label = "them"
            }
            let words = line.text.split(whereSeparator: \.isWhitespace).count
            let spoken = max(1.5, Double(words) / 2.5)
            let start = line.start ?? cursor
            let nextStart = index + 1 < lines.count ? lines[index + 1].start : nil
            var end = line.end ?? nextStart.map { $0 > start ? $0 : start + spoken } ?? start + spoken
            end = max(end, start)
            segments.append(Transcript.Segment(
                start: start, end: end, speaker: label, text: line.text,
                timingPrecision: line.start == nil ? .coarse : .span))
            cursor = max(cursor, end)
        }
        return Transcript(segments: segments, engine: "import-\(external.source.rawValue)", speakerAliases: aliases)
    }

    static func notesMarkdown(for external: ExternalMeeting) -> String? {
        var text = (external.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let unlisted = external.actionItems.filter { item in
            let itemText = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return !itemText.isEmpty && !text.localizedCaseInsensitiveContains(itemText)
        }
        if !unlisted.isEmpty {
            if !text.isEmpty { text += "\n\n" }
            text += "## Action items\n\n" + unlisted.map { item in
                let owner = item.owner?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return "- [ ] " + item.text.trimmingCharacters(in: .whitespacesAndNewlines) + (owner.isEmpty ? "" : " (\(owner))")
            }.joined(separator: "\n")
        }
        return text.isEmpty ? nil : text + "\n"
    }
}
