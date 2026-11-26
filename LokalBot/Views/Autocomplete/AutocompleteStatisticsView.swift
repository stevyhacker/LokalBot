import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

struct AutocompleteStatisticsView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var store: CotypingStatsStore

    @State private var range: CotypingUsageRange = .month
    @State private var chartMetric: ChartMetric = .words
    @State private var confirmingClear = false
    @State private var statsNotice: String?
    @State private var statsError: String?

    init(store: CotypingStatsStore = .shared) {
        self.store = store
    }

    enum ChartMetric: String, CaseIterable, Identifiable {
        case words, used

        var id: String { rawValue }

        var label: String {
            switch self {
            case .words: "Words"
            case .used: "Suggestions used"
            }
        }
    }

    var body: some View {
        if app.settings.cotypingEnabled || !store.usage.isEmpty {
            let summary = store.usage.summary(range)
            Section {
                Group {
                    if summary.total.isEmpty {
                        Label(store.usage.isEmpty
                              ? "Statistics appear here once you use autocomplete in other apps."
                              : "Autocomplete was not used in this period.",
                              systemImage: "chart.bar")
                            .font(AppFont.scaled(.callout))
                            .settingsSecondary()
                            .accessibilityIdentifier("autocomplete.statistics.empty")
                    } else {
                        tiles(summary)
                    }
                }
                .settingTarget("settings.autocompleteStatistics", selected: app.focusedSettingID)
                if !summary.total.isEmpty {
                    chart(summary)
                    breakdowns(summary)
                }
                shareSection(summary)
                footer
            } header: {
                HStack {
                    Text("Statistics")
                    Spacer()
                    Picker("Period", selection: $range) {
                        ForEach(CotypingUsageRange.allCases) { Text(LocalizedStringKey($0.label)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("autocomplete.statistics.range")
                }
            }
        }
    }

    private var language: AppLanguage { app.settings.appLanguage }

    private func tiles(_ summary: CotypingUsageSummary) -> some View {
        let counts = summary.total.suggestions
        let format = AutocompleteStatisticsPresentation.self
        return SettingsTileLayout {
            SettingsMetricTile(icon: "text.badge.checkmark", title: "Words accepted",
                               value: counts.words.formatted(), detail: format.wordsDetail(counts, language),
                               identifier: "autocomplete.statistics.words")
            SettingsMetricTile(icon: "checkmark.circle", title: "Suggestions used",
                               value: format.percent(counts.acceptanceRate), detail: format.usedDetail(counts, language),
                               identifier: "autocomplete.statistics.used")
            SettingsMetricTile(icon: "character.cursor.ibeam", title: "Of your text",
                               value: format.percent(summary.total.shareOfText),
                               detail: format.shareDetail(summary.total, language),
                               identifier: "autocomplete.statistics.share")
            SettingsMetricTile(icon: "clock", title: "Time saved",
                               value: format.timeSaved(summary.timeSavedSeconds),
                               detail: format.timeSavedDetail(summary, language),
                               identifier: "autocomplete.statistics.timeSaved")
        }
    }

    private func chart(_ summary: CotypingUsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(AutocompleteStatisticsPresentation.activeDetail(summary, language))
                    .font(AppFont.scaled(.callout))
                    .settingsSecondary()
                Spacer()
                Picker("Chart", selection: $chartMetric) {
                    ForEach(ChartMetric.allCases) { Text(LocalizedStringKey($0.label)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Chart(summary.bars) { bar in
                switch chartMetric {
                case .words:
                    BarMark(x: .value("Date", bar.start, unit: summary.barUnit),
                            y: .value("Words", bar.bucket.suggestions.words))
                        .foregroundStyle(Brand.teal)
                case .used:
                    if let rate = bar.bucket.suggestions.acceptanceRate {
                        BarMark(x: .value("Date", bar.start, unit: summary.barUnit),
                                y: .value("Suggestions used", rate))
                            .foregroundStyle(Brand.teal)
                    }
                }
            }
            .chartXScale(domain: AutocompleteStatisticsPresentation.domain(summary))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: summary.barUnit == .month ? 12 : 7)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: summary.barUnit == .month
                                   ? .dateTime.month(.abbreviated)
                                   : .dateTime.day().month(.abbreviated))
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if chartMetric == .used, let rate = value.as(Double.self) {
                            Text(rate.formatted(.percent.precision(.fractionLength(0))))
                        } else if let words = value.as(Int.self) {
                            Text(words.formatted())
                        }
                    }
                }
            }
            .chartYScale(domain: chartMetric == .used ? 0...1 : 0...AutocompleteStatisticsPresentation.wordCeiling(summary))
            .frame(height: 150)
            .accessibilityIdentifier("autocomplete.statistics.chart")
        }
        .padding(.top, 4)
    }

    @ViewBuilder private func breakdowns(_ summary: CotypingUsageSummary) -> some View {
        let surfaces = AutocompleteStatisticsPresentation.surfaceRows(summary.total, language)
        let models = AutocompleteStatisticsPresentation.modelRows(
            summary.total, displayName: { id in
                ModelCatalog.entry(id: id, custom: app.settings.customBuiltInModels)?.displayName ?? id
            })
        if surfaces.count > 1 {
            breakdown(title: "By kind of app", rows: surfaces, identifier: "surfaces")
        }
        if models.count > 1 {
            breakdown(title: "By model", rows: models, identifier: "models")
        }
    }

    private func breakdown(title: String, rows: [AutocompleteStatisticsPresentation.Row],
                           identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(title))
                .font(AppFont.scaled(.callout).weight(.semibold))
                .settingsSecondary()
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Text(verbatim: "")
                    Text("Shown").gridColumnAlignment(.trailing)
                    Text("Used").gridColumnAlignment(.trailing)
                    Text("Words").gridColumnAlignment(.trailing)
                    Text("Words per use").gridColumnAlignment(.trailing)
                    Text("Taken back").gridColumnAlignment(.trailing)
                }
                .settingsSecondary()
                ForEach(rows) { row in
                    GridRow {
                        Text(verbatim: row.title).lineLimit(1)
                        Text(row.counts.shown.formatted())
                        Text(AutocompleteStatisticsPresentation.percent(row.counts.acceptanceRate))
                        Text(row.counts.words.formatted())
                        Text(AutocompleteStatisticsPresentation.decimal(row.counts.wordsPerUsedSuggestion))
                        Text(row.counts.takenBack.formatted())
                    }
                    .monospacedDigit()
                }
            }
            .font(AppFont.scaled(.callout))
        }
        .padding(.top, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("autocomplete.statistics.\(identifier)")
    }

    private var ownMeetingsCount: Int {
        app.meetings.filter(\.isOwnWork).count
    }

    private func localStats(for summary: CotypingUsageSummary) -> LocalStatsSummary {
        LocalStatsSummary(summary: summary, meetingsCaptured: ownMeetingsCount)
    }

    private func shareSection(_ summary: CotypingUsageSummary) -> some View {
        let stats = localStats(for: summary)
        let hasAnyData = !summary.total.isEmpty || stats.meetingsCaptured > 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button("Copy Stats Summary") {
                    copyStatsSummary(stats)
                }
                .disabled(!hasAnyData)
                .accessibilityIdentifier("autocomplete.statistics.copySummary")

                Button("Save Stats Card (PNG)…") {
                    saveStatsCard(stats)
                }
                .disabled(!hasAnyData)
                .accessibilityIdentifier("autocomplete.statistics.saveCard")
            }
            if let statsNotice {
                Text(statsNotice)
                    .font(AppFont.scaled(.caption))
                    .settingsSecondary()
            }
            if let statsError {
                Text(statsError)
                    .font(AppFont.scaled(.caption))
                    .foregroundStyle(.red)
            }
        }
        .padding(.top, 4)
    }

    private func copyStatsSummary(_ stats: LocalStatsSummary) {
        statsError = nil
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(stats.plainTextSummary(), forType: .string)
        statsNotice = "Copied local stats summary (aggregate counts only)."
    }

    private func saveStatsCard(_ stats: LocalStatsSummary) {
        statsError = nil
        statsNotice = nil
        guard let pngData = LocalStatsCardRenderer.pngData(for: stats) else {
            statsError = "Could not render the stats card image."
            return
        }
        let panel = NSSavePanel()
        panel.title = "Save Local Stats Card"
        panel.nameFieldStringValue = "lokalbot-stats-\(range.rawValue).png"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try pngData.write(to: destination, options: .atomic)
            statsNotice = "Saved stats card PNG."
        } catch {
            statsError = "Could not save stats card: \(error.localizedDescription)"
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsHelp("Counted on this Mac while you type in other apps: suggestions shown and accepted, the characters you type yourself where autocomplete works, and the pauses between them, by day, kind of app and model. No text, app names or window titles are kept. Time saved is the keystrokes you did not type at your measured speed, not counting time spent reading suggestions.")
            Button("Clear statistics…", role: .destructive) { confirmingClear = true }
                .disabled(store.usage.isEmpty)
                .confirmationDialog("Clear autocomplete statistics?", isPresented: $confirmingClear) {
                    Button("Clear Statistics", role: .destructive) { store.clearUsage() }
                } message: {
                    Text("Deletes the daily and monthly counts. Usage and timing measurements are kept.")
                }
        }
    }
}

struct LocalStatsSummary: Equatable, Sendable {
    static let websiteHost = "lokalbot.com"

    var periodLabel: String
    var wordsAutocompleted: Int
    var acceptanceRate: Double?
    var timeSavedSeconds: Double
    var meetingsCaptured: Int

    init(summary: CotypingUsageSummary, meetingsCaptured: Int) {
        self.periodLabel = summary.range.label
        self.wordsAutocompleted = max(0, summary.total.suggestions.words)
        self.acceptanceRate = summary.total.suggestions.acceptanceRate
        self.timeSavedSeconds = max(0, summary.timeSavedSeconds)
        self.meetingsCaptured = max(0, meetingsCaptured)
    }

    init(
        periodLabel: String,
        wordsAutocompleted: Int,
        acceptanceRate: Double?,
        timeSavedSeconds: Double,
        meetingsCaptured: Int
    ) {
        self.periodLabel = periodLabel
        self.wordsAutocompleted = max(0, wordsAutocompleted)
        self.acceptanceRate = acceptanceRate
        self.timeSavedSeconds = max(0, timeSavedSeconds)
        self.meetingsCaptured = max(0, meetingsCaptured)
    }

    func plainTextSummary() -> String {
        let acceptance = AutocompleteStatisticsPresentation.percent(acceptanceRate)
        let saved = AutocompleteStatisticsPresentation.timeSaved(timeSavedSeconds)
        let meetingWord = meetingsCaptured == 1 ? "meeting" : "meetings"
        return [
            "LokalBot local stats (\(periodLabel))",
            "Words autocompleted: \(wordsAutocompleted.formatted())",
            "Suggestions accepted: \(acceptance)",
            "Time saved: \(saved)",
            "Meetings captured: \(meetingsCaptured.formatted()) \(meetingWord) (0 bots)",
            "Cloud API cost: $0",
            Self.websiteHost,
        ].joined(separator: "\n")
    }
}

struct LocalStatsCardView: View {
    let stats: LocalStatsSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "LokalBot")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Local stats · \(stats.periodLabel)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.68))
                }
                Spacer()
                Text("$0 cloud API cost")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 0.14, green: 0.80, blue: 0.71))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color(red: 0.14, green: 0.80, blue: 0.71).opacity(0.16), in: Capsule())
            }

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
                spacing: 14
            ) {
                statTile(title: "Words autocompleted", value: stats.wordsAutocompleted.formatted())
                statTile(title: "Suggestions accepted", value: AutocompleteStatisticsPresentation.percent(stats.acceptanceRate))
                statTile(title: "Time saved", value: AutocompleteStatisticsPresentation.timeSaved(stats.timeSavedSeconds))
                statTile(title: "Meetings captured", value: "\(stats.meetingsCaptured.formatted()) · 0 bots")
            }

            HStack {
                Text("100% local processing · aggregate counts only")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.58))
                Spacer()
                Text(LocalStatsSummary.websiteHost)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(red: 0.14, green: 0.80, blue: 0.71))
            }
        }
        .padding(28)
        .frame(width: 600, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.04, green: 0.07, blue: 0.11),
                            Color(red: 0.06, green: 0.11, blue: 0.16),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    private func statTile(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.66))
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

@MainActor
enum LocalStatsCardRenderer {
    static func pngData(for stats: LocalStatsSummary) -> Data? {
        let renderer = ImageRenderer(content: LocalStatsCardView(stats: stats))
        renderer.scale = 2.0
        guard let cgImage = renderer.cgImage else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        return bitmap.representation(using: .png, properties: [:])
    }
}

enum AutocompleteStatisticsPresentation {
    struct Row: Identifiable, Equatable {
        var id: String
        var title: String
        var counts: CotypingUsageCounts
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.formatted(.percent.precision(.fractionLength(0)))
    }

    static func decimal(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.precision(.fractionLength(1)))
    }

    static func timeSaved(_ seconds: Double) -> String {
        let rounded = seconds.rounded()
        guard rounded > 0 else { return "0" }
        let units: Set<Duration.UnitsFormatStyle.Unit> = rounded < 60 ? [.seconds]
            : rounded < 3_600 ? [.minutes] : [.hours, .minutes]
        return "≈ " + Duration.seconds(rounded).formatted(.units(allowed: units, width: .abbreviated))
    }

    static func wordsDetail(_ counts: CotypingUsageCounts, _ language: AppLanguage) -> String {
        var parts: [String] = []
        if let perUse = counts.wordsPerUsedSuggestion {
            parts.append(String(format: language.localized("%@ per suggestion used"), decimal(perUse)))
        }
        if counts.takenBack > 0 {
            parts.append(String(format: language.localized("%@ taken back"), counts.takenBack.formatted()))
        }
        return parts.isEmpty ? language.localized("None accepted yet") : parts.joined(separator: " · ")
    }

    static func usedDetail(_ counts: CotypingUsageCounts, _ language: AppLanguage) -> String {
        String(format: language.localized("%@ of %@ shown"),
               min(counts.used, counts.shown).formatted(), counts.shown.formatted())
    }

    static func shareDetail(_ bucket: CotypingUsageBucket, _ language: AppLanguage) -> String {
        let total = bucket.suggestions.characters + bucket.typedCharacters
        return String(format: language.localized("%@ of %@ characters written"),
                      bucket.suggestions.characters.formatted(), total.formatted())
    }

    static func timeSavedDetail(_ summary: CotypingUsageSummary, _ language: AppLanguage) -> String {
        let keystrokes = summary.total.suggestions.keystrokesSaved.formatted()
        if let wpm = summary.wordsPerMinute {
            return String(format: language.localized("%@ keystrokes at your %@ words a minute"),
                          keystrokes, wpm.formatted())
        }
        return String(format: language.localized("%@ keystrokes at 40 words a minute until your speed is measured"),
                      keystrokes)
    }

    static func activeDetail(_ summary: CotypingUsageSummary, _ language: AppLanguage) -> String {
        let format = summary.barUnit == .month ? "Used in %@ of %@ months" : "Used on %@ of %@ days"
        var text = String(format: language.localized(format),
                          summary.activeBars.formatted(), summary.bars.count.formatted())
        if summary.total.typosFixed > 0 {
            text += " · " + String(format: language.localized("%@ typos fixed"), summary.total.typosFixed.formatted())
        }
        return text
    }

    static func surfaceRows(_ bucket: CotypingUsageBucket, _ language: AppLanguage) -> [Row] {
        CotypingSurfaceClass.measured.compactMap { surface -> Row? in
            guard let counts = bucket.surfaces[surface.rawValue], counts.shown > 0 || counts.words > 0 else { return nil }
            return Row(id: surface.rawValue, title: language.localized(surface.measureTitle), counts: counts)
        }
        .sorted { $0.counts.words > $1.counts.words }
    }

    static func modelRows(_ bucket: CotypingUsageBucket, displayName: (String) -> String) -> [Row] {
        bucket.models
            .filter { $0.value.shown > 0 }
            .map { Row(id: $0.key, title: displayName($0.key), counts: $0.value) }
            .sorted { ($0.counts.shown, $1.title) > ($1.counts.shown, $0.title) }
    }

    static func domain(_ summary: CotypingUsageSummary, calendar: Calendar = .current) -> ClosedRange<Date> {
        let start = summary.bars.first?.start ?? Date()
        let last = summary.bars.last?.start ?? start
        let end = calendar.date(byAdding: summary.barUnit, value: 1, to: last) ?? last
        return start...end
    }

    static func wordCeiling(_ summary: CotypingUsageSummary) -> Int {
        let tallest = summary.bars.map(\.bucket.suggestions.words).max() ?? 0
        return max(10, tallest + (tallest + 9) / 10)
    }
}
