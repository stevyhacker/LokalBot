import SwiftUI

/// Observed activity sessions are separate from the digest's generated tasks.
struct TodaySessionsSection: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var model: CaptureModel
    @State private var showsAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Sessions").font(.scaled(.headline))
                Spacer()
                Button("Open Timeline") { app.navSection = .timeline }.buttonStyle(.workspaceLink)
            }
            ForEach(showsAll ? model.workSessions : Array(model.workSessions.prefix(4))) { session in
                Button {
                    if let moment = model.shots.first(where: { $0.ts >= session.start && $0.ts <= session.end }) {
                        app.openScreenSnapshot(moment.id)
                    } else {
                        app.navSection = .timeline
                    }
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "briefcase").foregroundStyle(Brand.teal).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(session.title).font(.scaled(.body).weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                            Text(session.apps.joined(separator: " · ")).font(.scaled(.callout)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 5) {
                            Text(session.start.formatted(date: .omitted, time: .shortened))
                            Text(CaptureStyle.hm(session.activeDuration))
                        }
                        .font(.scaled(.callout).monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12).lbGroupedSurface()
                }
                .buttonStyle(.plain)
            }
            if model.workSessions.count > 4 {
                Button(showsAll ? "Show Fewer Sessions" : "Show All \(model.workSessions.count) Sessions") {
                    showsAll.toggle()
                }.buttonStyle(.workspaceLink)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today.sessions")
    }
}
