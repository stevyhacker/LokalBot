import CryptoKit
import Foundation

extension DreamStore {
    func withMeetingEvidenceMutation<T>(for meetings: [Meeting], _ mutation: () throws -> T) throws -> T {
        try withSourceEvidenceMutation(on: meetings.map(\.startedAt), meetings: meetings,
                                       meetingIDs: Set(meetings.map(\.id)), mutation)
    }

    func withMeetingEvidenceMutation<T>(for meetings: [Meeting], folders: [URL],
                                        _ mutation: () throws -> T) throws -> T {
        guard !meetings.isEmpty else { return try mutation() }
        let reportKeys = DreamEvidenceInvalidation.dayKeys(
            affectedDays: meetings.map(\.startedAt), through: Date(), calendar: .current)
        return try withEvidenceMutation(
            affectedDayKeys: DreamEvidenceInvalidation.meetingDayKeys(for: meetings),
            affectedMeetingIDs: Set(meetings.map(\.id)), reportDayKeys: reportKeys,
            unlessUnchanged: { MeetingEvidenceFingerprint.of(folders) }, mutation)
    }

    func withScreenEvidenceMutation<T>(on dates: [Date], _ mutation: () throws -> T) throws -> T {
        try withSourceEvidenceMutation(on: dates, meetings: [], meetingIDs: [], mutation)
    }

    private func withSourceEvidenceMutation<T>(
        on dates: [Date], meetings: [Meeting], meetingIDs: Set<UUID>, _ mutation: () throws -> T
    ) throws -> T {
        guard !dates.isEmpty || !meetingIDs.isEmpty else { return try mutation() }
        let calendar = Calendar.current
        let activityOnly = meetingIDs.isEmpty
        let reportKeys = DreamEvidenceInvalidation.dayKeys(
            affectedDays: dates, through: Date(), calendar: calendar,
            comparisonWindowDays: activityOnly ? 1 : DreamCompiler.comparisonWindowDays)
        return try withEvidenceMutation(
            affectedDayKeys: activityOnly
                ? DreamEvidenceInvalidation.sourceDayKeys(for: dates)
                : DreamEvidenceInvalidation.meetingDayKeys(for: meetings),
            affectedMeetingIDs: meetingIDs, reportDayKeys: reportKeys,
            activityOnly: activityOnly, mutation)
    }
}

extension DreamEvidenceInvalidation {
    static func meetingDayKeys(for meetings: [Meeting]) -> Set<String> {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        var keys: Set<String> = []
        for meeting in meetings {
            let end = max(meeting.endedAt ?? meeting.startedAt, meeting.startedAt)
            guard var day = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: meeting.startedAt)),
                  let last = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)) else { continue }
            while day <= last {
                keys.insert(DreamDay.key(for: day, calendar: calendar))
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        return keys
    }

    static func sourceDayKeys(for dates: [Date]) -> Set<String> {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return Set(dates.flatMap { date in
            (-2...2).compactMap { offset in
                calendar.date(byAdding: .day, value: offset, to: date)
                    .map { DreamDay.key(for: $0, calendar: calendar) }
            }
        })
    }
}

enum MeetingEvidenceFingerprint {
    static let extensions: Set<String> = ["json", "md", "txt"]

    static func of(_ folders: [URL]) -> Data? {
        var hasher = SHA256()
        let fileManager = FileManager.default
        for folder in folders.sorted(by: { $0.path < $1.path }) {
            hasher.update(data: Data(folder.path.utf8))
            guard let enumerator = fileManager.enumerator(
                at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            var files: [URL] = []
            for case let url as URL in enumerator
            where extensions.contains(url.pathExtension.lowercased())
                && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                files.append(url)
            }
            for url in files.sorted(by: { $0.path < $1.path }) {
                guard let data = try? Data(contentsOf: url) else { return nil }
                hasher.update(data: Data(url.path.utf8))
                hasher.update(data: Data(String(data.count).utf8))
                hasher.update(data: data)
            }
        }
        return Data(hasher.finalize())
    }
}
