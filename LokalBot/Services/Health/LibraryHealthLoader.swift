import Foundation

@MainActor
struct LibraryHealthLoader {
    let activityStore: ActivityStore
    let storageRoot: URL
    let meetings: [Meeting]
    let queuedMeetingIDs: Set<Meeting.ID>
    let settings: AppSettings
    let hasDreamReport: (String) -> Bool

    static func journalURL(root: URL, day: Date, calendar: Calendar = .current) -> URL {
        root.appendingPathComponent("journal/\(DreamDay.key(for: day, calendar: calendar)).md")
    }

    func input(for day: Date, now: Date, calendar: Calendar = .current) -> LibraryHealthInput {
        let interval = ActivityStore.dayInterval(containing: day, calendar: calendar)
        let captures = activityStore.screenshots(in: interval, includingMissingFiles: true)
        return LibraryHealthInput(
            day: interval,
            now: now,
            blocks: activityStore.blocks(in: interval),
            screenCaptureEnabled: settings.trackingEnabled
                && settings.effectiveScreenContextCaptureMode.capturesText,
            captureCountsByApp: Dictionary(grouping: captures, by: \.app).mapValues(\.count),
            privateShareHistory: privateShareHistory(before: interval.start, calendar: calendar),
            recordings: recordings(now: now),
            automaticTranscription: settings.autoTranscribe,
            schedulers: schedulers(now: now, calendar: calendar),
            digestCoverage: DayDigestGenerationMetadataStore.load(
                for: Self.journalURL(root: storageRoot, day: day, calendar: calendar))?.coverage)
    }

    private func privateShareHistory(before start: Date, calendar: Calendar) -> [Double] {
        (1...7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: start) else { return nil }
            let blocks = LibraryHealthEvaluator.clampedBlocks(
                activityStore.blocks(on: day),
                to: ActivityStore.dayInterval(containing: day, calendar: calendar))
            let tracked = blocks.reduce(0) { $0 + $1.duration }
            guard tracked > 0 else { return nil }
            let hidden = blocks.filter { $0.app == LibraryHealthEvaluator.privateApp }.reduce(0) { $0 + $1.duration }
            return hidden / tracked
        }
    }

    private func recordings(now: Date) -> [LibraryHealthInput.Recording] {
        let cutoff = now.addingTimeInterval(-7 * 86_400)
        return meetings
            .filter { ($0.endedAt ?? .distantPast) >= cutoff }
            .map { meeting in
                LibraryHealthInput.Recording(
                    meetingID: meeting.id,
                    title: meeting.title,
                    missingTranscript: MissingTranscription.reason(
                        for: meeting,
                        folder: storageRoot.appendingPathComponent(meeting.relativePath, isDirectory: true)),
                    hasQueuedJob: queuedMeetingIDs.contains(meeting.id))
            }
    }

    private func schedulers(now: Date, calendar: Calendar) -> LibraryHealthInput.Schedulers {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let journal = Self.journalURL(root: storageRoot, day: yesterday, calendar: calendar)
        return LibraryHealthInput.Schedulers(
            automaticInferenceAllowed: settings.allowsAutomaticMainInference,
            digestEnabled: settings.dayDigestAutoEnabled,
            previousDay: DayDigestScheduler.PastDay(
                day: yesterday,
                latestEvidenceAt: activityStore.latestEvidenceAt(on: yesterday),
                digestModifiedAt: DayDigestGenerationMetadataStore.completedAt(for: journal)),
            dreamingEnabled: settings.dreamingEnabled,
            dreamingHour: settings.dreamingHour,
            missingDreamDays: missingDreamDays(through: yesterday, calendar: calendar))
    }

    private func missingDreamDays(through yesterday: Date, calendar: Calendar) -> Int {
        guard settings.dreamingEnabled else { return 0 }
        let windowStart = calendar.date(byAdding: .day, value: -(DreamScheduler.catchUpDays - 1), to: yesterday)
            ?? yesterday
        let firstEligible = settings.dreamingFirstEligibleDayKey
            .flatMap { DreamDay.date(fromKey: $0, calendar: calendar) } ?? yesterday
        var day = calendar.startOfDay(for: max(windowStart, firstEligible))
        var missing = 0
        while day <= yesterday {
            if !hasDreamReport(DreamDay.key(for: day, calendar: calendar)) { missing += 1 }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return missing
    }
}
