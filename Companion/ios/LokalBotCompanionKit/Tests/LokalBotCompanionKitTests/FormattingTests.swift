import Foundation
import Testing
@testable import LokalBotCompanionKit

@Suite("Formatting")
struct FormattingTests {
    static let format: LBFormat = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Podgorica")!
        calendar.locale = Locale(identifier: "en_US")
        return LBFormat(locale: Locale(identifier: "en_US"), calendar: calendar)
    }()

    /// ICU puts a narrow no-break space before AM/PM.
    static func plain(_ text: String) -> String { text.replacingOccurrences(of: "\u{202F}", with: " ") }

    @Test func transcriptTimestamps() {
        #expect(LBFormat.stamp(0) == "00:00:00")
        #expect(LBFormat.stamp(721.4) == "00:12:01")
        #expect(LBFormat.stamp(59.99) == "00:00:59")
        #expect(LBFormat.stamp(3725) == "01:02:05")
        #expect(LBFormat.stamp(36_000) == "10:00:00")
        #expect(LBFormat.stamp(-3) == "00:00:00")
    }

    @Test func durations() {
        #expect(LBFormat.meetingDuration(2520) == "42 min")
        #expect(LBFormat.meetingDuration(3900) == "1 hr 5 min")
        #expect(LBFormat.hm(30) == "<1m")
        #expect(LBFormat.hm(0) == "0m")
        #expect(LBFormat.hm(16380) == "4h 33m")
    }

    @Test func meetingTimesUseTheMacsOffset() async throws {
        let store = try FixtureStore.sampleLibrary()
        let meeting = try #require(await store.meeting(id: "3f6c2a10-8a4e-4d2b-9b1e-0a1b2c3d4e01"))
        // 09:30Z at +60 min is 10:30 on the Mac, whatever this device's zone.
        #expect(Self.plain(Self.format.time(meeting.startedAt, in: meeting.timeZone)) == "10:30 AM")
        #expect(Self.plain(Self.format.time(in: meeting, at: 724)) == "10:42 AM")
        var tokyo = Self.format
        tokyo.calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        #expect(Self.plain(tokyo.time(in: meeting, at: 724)) == "10:42 AM")
    }

    @Test func dueDates() {
        let today = DayKey("2026-10-31")!
        let f = Self.format
        #expect(f.due("2026-10-30", status: .open, today: today) == .init(text: "Overdue · Fri", isOverdue: true))
        #expect(f.due("2026-10-20", status: .open, today: today) == .init(text: "Overdue · Oct 20", isOverdue: true))
        #expect(f.due("2026-10-31", status: .open, today: today)?.text == "Due today")
        #expect(f.due("2026-11-01", status: .open, today: today)?.text == "Due tomorrow")
        #expect(f.due("2026-11-03", status: .open, today: today)?.text == "Due Tue")
        #expect(f.due("2026-11-12", status: .open, today: today)?.text == "Due Thu, Nov 12")
        #expect(f.due("2026-10-30", status: .done, today: today) == .init(text: "Due Fri, Oct 30", isOverdue: false))
        #expect(f.due(nil, status: .open, today: today) == nil)
        #expect(f.due("by Thursday", status: .open, today: today) == nil)
    }

    @Test func dayTitles() {
        let today = DayKey("2026-10-31")!
        let f = Self.format
        #expect(f.dayTitle(today, today: today) == "Today")
        #expect(f.dayTitle(DayKey("2026-10-30")!, today: today) == "Yesterday")
        #expect(f.dayTitle(DayKey("2026-10-27")!, today: today) == "Tuesday")
        #expect(f.dayTitle(DayKey("2026-10-20")!, today: today) == "Tue, Oct 20")
        #expect(f.longDay(today) == "Saturday, October 31")
    }

    @Test func dayKeys() {
        let key = DayKey("2026-02-28")!
        #expect(key.adding(days: 1).description == "2026-03-01")
        #expect(key.adding(days: -59).description == "2025-12-31")
        #expect(DayKey("2026-13-01") == nil)
        #expect(DayKey("2026-1-1")?.description == nil)
        #expect(DayKey("2026-10-30")! < DayKey("2026-10-31")!)
        #expect(DayKey("2026-10-01")!.days(until: DayKey("2026-11-01")!) == 31)
    }

    @Test func syncAgo() {
        let now = CompanionJSON.parseInstant("2026-10-31T10:12:00.000Z")!
        let f = Self.format
        #expect(f.ago(now.addingTimeInterval(-20), now: now) == "just now")
        #expect(f.ago(now.addingTimeInterval(-120), now: now) == "2 min ago")
        #expect(f.ago(now.addingTimeInterval(-3 * 3600), now: now) == "3 hr ago")
        #expect(f.ago(now.addingTimeInterval(-20 * 3600), now: now) == "yesterday")
        #expect(f.ago(now.addingTimeInterval(-4 * 86_400), now: now) == "Oct 27")
    }

    @Test @MainActor func syncPillText() {
        let now = CompanionJSON.parseInstant("2026-10-31T10:12:00.000Z")!
        let synced = SyncStatusPill(state: .synced(at: now.addingTimeInterval(-120), route: .localNetwork), format: Self.format)
        #expect(synced.text(now: now) == "Synced with your Mac · 2 min ago · Wi-Fi")
        let away = SyncStatusPill(state: .unreachable(lastSync: now.addingTimeInterval(-7200)), format: Self.format)
        #expect(away.text(now: now) == "Mac not reachable · last synced 2 hr ago")
    }
}
