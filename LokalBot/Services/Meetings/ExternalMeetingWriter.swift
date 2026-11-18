import CryptoKit
import Foundation

/// Stores a meeting read from another app (`ExternalMeeting`) as a LokalBot
/// meeting. The source's transcript becomes `transcript.json`, its notes
/// `summary.md` (with an untouched copy in `imported-notes.md`), and a
/// recording that came with it goes through `MeetingImportService`. The
/// source files are only read. `meta.json` is written last, so the library
/// never lists a half-made meeting.
enum ExternalMeetingWriter {
    /// Where the source's own notes are kept unchanged, so writing LokalBot
    /// notes for the meeting later never loses them.
    static let importedNotesFileName = "imported-notes.md"

    struct Result: Equatable {
        var meeting: Meeting
        /// A recording came without a transcript, so LokalBot transcribes it.
        var needsTranscription: Bool
    }

    /// The same source meeting always gets the same LokalBot id, so an
    /// import interrupted after its audio was saved is still recognized.
    static func meetingID(for external: ExternalMeeting) -> UUID {
        let digest = Array(SHA256.hash(data: Data("lokalbot-import/\(external.importKey)".utf8)))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Whether `library` already holds this meeting from an earlier import.
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
            // A text-only meeting isn't listed until meta.json exists, so
            // nothing half-made stays behind. A recording's meeting is kept:
            // its audio is safe and its id still marks it imported.
            if external.audioURL == nil { try? FileManager.default.removeItem(at: folder) }
            throw error
        }
        return Result(meeting: meeting, needsTranscription: external.audioURL != nil && transcript == nil)
    }

    /// Voice Memos are recorded on the person's own microphone, so "My
    /// microphone is me" applies to them; other sources' recordings are calls.
    static func recordingTrack(for source: ExternalMeetingSource) -> MeetingAudioFiles.Track {
        source == .voiceMemos ? .mic : .system
    }

    static func title(for external: ExternalMeeting) -> String {
        let cleaned = external.title.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "\(external.source.title) meeting" : cleaned
    }

    /// When the source kept no start: the file's modification date, which an
    /// export usually leaves at the meeting's day or later, never the future.
    private static func fallbackStart(for external: ExternalMeeting, now: Date) -> Date {
        let modified = (try? external.origin.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        return min(modified ?? now, now)
    }

    /// The source's lines as a LokalBot transcript. Each named speaker gets a
    /// stable label ("them 1", "them 2", …) with their name as its alias; the
    /// person's own microphone lines are "me". Lines the source kept without
    /// times are laid out one after another at speaking pace, marked coarse.
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

    /// The source's notes, with its action items listed after them unless
    /// the notes already say them.
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
