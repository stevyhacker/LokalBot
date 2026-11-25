import Foundation

enum WisprFlowMeetingReader: ExternalMeetingReader {
    static let source = ExternalMeetingSource.wisprFlow
    static let exportHint = "Choose Wispr Flow's folder or its flow.sqlite database. Meetings come with their transcript, speakers and summary; nothing needs exporting."
    static let defaultLocations = ["~/Library/Application Support/Wispr Flow"]
    static let meetingsFolderName = "meetings"
    static let transcriptFileName = "refined.ndjson"

    struct Speaker: Equatable, Sendable {
        var name: String
        var isMe: Bool
    }

    static func recognizes(_ url: URL) -> Bool {
        let database = WisprFlowLibrary.databaseURL(for: url)
        return database.lastPathComponent == WisprFlowLibrary.databaseName
            && FileManager.default.fileExists(atPath: database.path)
    }

    static func read(_ url: URL) throws -> ExternalImportScan {
        guard FileManager.default.fileExists(atPath: url.path) else { throw ExternalImportError.notFound(url.path) }
        let database = WisprFlowLibrary.databaseURL(for: url)
        guard database.lastPathComponent == WisprFlowLibrary.databaseName else {
            throw ExternalImportError.unrecognized(source, url.path)
        }
        let folder = database.deletingLastPathComponent().appendingPathComponent(meetingsFolderName, isDirectory: true)
        let records = try WisprFlowLibrary.meetings(at: database)
        var scan = ExternalImportScan()
        for record in records where !record.isDeleted && !record.isTourDemo {
            if let meeting = meeting(record, folder: folder, origin: database, problems: &scan.problems) {
                scan.meetings.append(meeting)
            }
        }
        return scan
    }

    static func transcriptURL(id: String, folder: URL) -> URL? {
        guard !id.isEmpty, !id.contains("/"), id != ".", id != ".." else { return nil }
        let transcript = folder.appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent(transcriptFileName)
        guard transcript.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/") else { return nil }
        return transcript
    }

    static func meeting(_ record: WisprFlowLibrary.MeetingRecord, folder: URL, origin: URL,
                        problems: inout [ExternalImportScan.Problem]) -> ExternalMeeting? {
        guard let transcript = transcriptURL(id: record.id, folder: folder) else {
            problems.append(.init(path: origin.path, reason: "A meeting has an id that isn't a valid folder name, so it was skipped."))
            return nil
        }
        let speakers = speakers(record.speakerMap)
        let transcriptLines: (lines: [ExternalMeeting.Line], badRows: Int)
        do {
            transcriptLines = try lines(transcript, speakers: speakers)
            if transcriptLines.lines.isEmpty, transcriptLines.badRows > 0 { throw CocoaError(.fileReadCorruptFile) }
        } catch {
            problems.append(.init(path: transcript.path, reason: "The transcript exists but couldn't be read, so this meeting was skipped. Import again once it can be read."))
            return nil
        }
        if transcriptLines.badRows > 0 {
            problems.append(.init(path: transcript.path, reason: "\(transcriptLines.badRows) transcript line(s) couldn't be read and were left out."))
        }
        let startedAt = record.createdAt.flatMap(date)
        var duration = record.recordedMs.map { $0 / 1000 }
        if duration == nil, let startedAt, let endedAt = record.endedAt {
            duration = max(0, endedAt / 1000 - startedAt.timeIntervalSince1970)
        }
        return ExternalMeeting(
            source: source,
            sourceID: record.id,
            title: (record.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            startedAt: startedAt,
            duration: duration,
            participants: participants(record.participantNames, speakers: speakers),
            lines: transcriptLines.lines,
            notes: record.summary.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 },
            origin: origin)
    }

    static func lines(_ url: URL, speakers: [Int: Speaker]) throws -> (lines: [ExternalMeeting.Line], badRows: Int) {
        guard FileManager.default.fileExists(atPath: url.path) else { return ([], 0) }
        let text = try String(contentsOf: url, encoding: .utf8)
        var lines: [ExternalMeeting.Line] = []
        var badRows = 0
        for row in text.split(whereSeparator: \.isNewline) {
            guard let data = row.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                badRows += 1
                continue
            }
            guard let words = (object["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !words.isEmpty else { continue }
            let speakerID = ((object["speaker"] as? [String: Any])?["id"] as? NSNumber)?.intValue
            let speaker = speakerID.flatMap { speakers[$0] }
            lines.append(ExternalMeeting.Line(
                start: (object["timestamp"] as? String).flatMap(seconds),
                speaker: speaker?.name ?? speakerID.map { "Speaker \($0)" },
                text: words,
                isMe: speaker?.isMe ?? false))
        }
        for index in lines.indices.dropLast() {
            if let start = lines[index].start, let next = lines[index + 1].start, next > start {
                lines[index].end = next
            }
        }
        return (lines, badRows)
    }

    static let assignmentSources = ["user", "consensus", "dom", "mic", "llm"]

    static func speakers(_ json: String?) -> [Int: Speaker] {
        guard let data = json?.data(using: .utf8),
              let map = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let people = map["people"] as? [String: [String: Any]],
              let assignments = map["assignments"] as? [String: [String: Any]] else { return [:] }
        let ownNames = Set(people.values.filter { $0["origin"] as? String == "self" }.compactMap {
            ($0["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty })
        var result: [Int: Speaker] = [:]
        for (key, assignment) in assignments {
            guard let id = Int(key) else { continue }
            let named = assignmentSources.lazy.compactMap { source -> Speaker? in
                guard let person = (assignment[source] as? String).flatMap({ people[$0] }),
                      let name = (person["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty else { return nil }
                return Speaker(name: name, isMe: person["origin"] as? String == "self" || ownNames.contains(name.lowercased()))
            }
            if let speaker = named.first { result[id] = speaker }
        }
        return result
    }

    static func participants(_ json: String?, speakers: [Int: Speaker]) -> [String] {
        var names = (json?.data(using: .utf8)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String] } ?? []
        names += speakers.keys.sorted().compactMap { speakers[$0] }.filter { !$0.isMe }.map(\.name)
        var seen = Set<String>()
        return names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    static func seconds(_ timestamp: String) -> TimeInterval? {
        let parts = timestamp.split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part), value >= 0 else { return nil }
            total = total * 60 + value
        }
        return total
    }

    static func date(_ text: String) -> Date? {
        for format in ["yyyy-MM-dd HH:mm:ss.SSS xxx", "yyyy-MM-dd HH:mm:ss xxx", "yyyy-MM-dd'T'HH:mm:ss.SSSXXX"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
