import SwiftUI

struct DayActivityOverview: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var model: CaptureModel
    var title = "Day Overview"
    var showsLegend = true

    private var perApp: [(label: String, seconds: TimeInterval)] {
        Dictionary(grouping: model.blocks.filter { !TimelineWorkSession.isSystemOnly(app: $0.app) }, by: \.app)
            .map { (label: $0.key, seconds: $0.value.reduce(0) { $0 + $1.duration }) }
            .sorted { $0.seconds > $1.seconds }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.scaled(.headline))
            ViewThatFits(in: .horizontal) {
                DayStatRow(trackedSeconds: perApp.reduce(0) { $0 + $1.seconds }, appCount: perApp.count,
                           momentCount: model.shots.count, meetingCount: model.meetings(in: app).count)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        StatTile(icon: "clock", value: CaptureStyle.hm(perApp.reduce(0) { $0 + $1.seconds }), label: "tracked")
                        StatTile(icon: "square.grid.2x2", value: "\(perApp.count)", label: "apps")
                    }
                    HStack {
                        StatTile(icon: "rectangle.on.rectangle", value: "\(model.shots.count)", label: "moments")
                        StatTile(icon: "waveform", value: "\(model.meetings(in: app).count)", label: "meetings")
                    }
                }
            }
            if !perApp.isEmpty {
                ProportionBar(segments: ProportionBarMath.segments(perApp: perApp).map {
                    ($0, $0.label == "Other" ? Color.gray : CaptureStyle.color(for: $0.label))
                })
                if showsLegend {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 8) {
                        ForEach(AppTimePresentation.rows(perApp: perApp), id: \.label) { row in
                            HStack(spacing: 6) {
                                StatusDot(color: row.isOther ? .gray : CaptureStyle.color(for: row.label), size: 6)
                                Text(row.label).lineLimit(1)
                                Text(CaptureStyle.hm(row.seconds)).monospacedDigit().foregroundStyle(.secondary)
                            }.font(.scaled(.callout))
                        }
                    }
                }
            }
        }
    }
}
