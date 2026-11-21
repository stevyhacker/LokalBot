import Foundation

enum DreamEvidenceInvalidation {
    static func dayKeys(
        affectedDays: [Date], through latestDay: Date, calendar: Calendar,
        comparisonWindowDays: Int = DreamCompiler.comparisonWindowDays
    ) -> Set<String> {
        let lastDay = calendar.startOfDay(for: latestDay)
        let firstDays = Set(affectedDays.map { calendar.startOfDay(for: $0) })
        var keys: Set<String> = []
        for first in firstDays {
            for offset in 0..<max(1, comparisonWindowDays) {
                guard let day = calendar.date(byAdding: .day, value: offset, to: first), day <= lastDay else { break }
                keys.insert(DreamDay.key(for: day, calendar: calendar))
            }
        }
        return keys
    }
}
