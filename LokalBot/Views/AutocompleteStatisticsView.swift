import Charts
import SwiftUI

/// Settings → Autocomplete → Statistics: how much autocomplete wrote for you. It
/// counts what was shown as well as what was taken, and what you typed
/// yourself, so it can say how often a suggestion is used and how much of
/// your text it wrote, and it prices keystrokes at your own typing speed.
struct AutocompleteStatisticsView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var store: CotypingStatsStore

    @State private var range: CotypingUsageRange = .month
    @State private var chartMetric: ChartMetric = .words
    @State private var confirmingClear = false

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
        // Nothing to show and nothing coming: autocomplete was never used and is off.
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
                footer
            } header: {
                // The period applies to everything below, so it sits with the title.
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

    // MARK: - Headline numbers

    private var language: AppLanguage { app.settings.appLanguage }

    /// Four across when they fit, otherwise two by two; tiles in a row share its height.
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

    // MARK: - Chart

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

    // MARK: - Breakdowns

    @ViewBuilder private func breakdowns(_ summary: CotypingUsageSummary) -> some View {
        let surfaces = AutocompleteStatisticsPresentation.surfaceRows(summary.total, language)
        let models = AutocompleteStatisticsPresentation.modelRows(
            summary.total, displayName: { id in
                ModelCatalog.entry(id: id, custom: app.settings.customBuiltInModels)?.displayName ?? id
            })
        if surfaces.count > 1 {
            breakdown(title: "By kind of app", rows: surfaces, identifier: "surfaces")
        }
        // A model column says something only once there is another to compare.
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

    // MARK: - Footer

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

/// Wording and number formats for the statistics, apart from the view so
/// they can be tested.
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

    /// "≈ 3 hr, 25 min", "≈ 41 min", "≈ 50 sec".
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

    /// "Used on 12 of 30 days · 4 typos fixed".
    static func activeDetail(_ summary: CotypingUsageSummary, _ language: AppLanguage) -> String {
        let format = summary.barUnit == .month ? "Used in %@ of %@ months" : "Used on %@ of %@ days"
        var text = String(format: language.localized(format),
                          summary.activeBars.formatted(), summary.bars.count.formatted())
        if summary.total.typosFixed > 0 {
            text += " · " + String(format: language.localized("%@ typos fixed"), summary.total.typosFixed.formatted())
        }
        return text
    }

    /// Kinds of app with any suggestion shown, most words first.
    static func surfaceRows(_ bucket: CotypingUsageBucket, _ language: AppLanguage) -> [Row] {
        CotypingSurfaceClass.measured.compactMap { surface -> Row? in
            guard let counts = bucket.surfaces[surface.rawValue], counts.shown > 0 || counts.words > 0 else { return nil }
            return Row(id: surface.rawValue, title: language.localized(surface.measureTitle), counts: counts)
        }
        .sorted { $0.counts.words > $1.counts.words }
    }

    /// Models with any suggestion shown, most shown first.
    static func modelRows(_ bucket: CotypingUsageBucket, displayName: (String) -> String) -> [Row] {
        bucket.models
            .filter { $0.value.shown > 0 }
            .map { Row(id: $0.key, title: displayName($0.key), counts: $0.value) }
            .sorted { ($0.counts.shown, $1.title) > ($1.counts.shown, $0.title) }
    }

    /// The chart spans whole periods, so the first and last bars are not cut in half.
    static func domain(_ summary: CotypingUsageSummary, calendar: Calendar = .current) -> ClosedRange<Date> {
        let start = summary.bars.first?.start ?? Date()
        let last = summary.bars.last?.start ?? start
        let end = calendar.date(byAdding: summary.barUnit, value: 1, to: last) ?? last
        return start...end
    }

    /// Headroom above the tallest bar, and a floor so a quiet week is not drawn full height.
    static func wordCeiling(_ summary: CotypingUsageSummary) -> Int {
        let tallest = summary.bars.map(\.bucket.suggestions.words).max() ?? 0
        return max(10, tallest + (tallest + 9) / 10)
    }
}
