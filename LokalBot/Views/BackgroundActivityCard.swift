import SwiftUI

/// Sticky sidebar summary of long-running model work. It shows the most
/// important activity and lists the rest in a popover; each row opens the
/// screen that owns its work.
struct BackgroundActivityCard: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var monitor: BackgroundActivityMonitor
    @State private var showingAll = false

    var body: some View {
        if let primary = monitor.activities.first {
            VStack(alignment: .leading, spacing: 6) {
                BackgroundActivityButton(activity: primary, open: app.openBackgroundActivity)
                if monitor.activities.count > 1 {
                    Button("+\(monitor.activities.count - 1) more") { showingAll = true }
                        .buttonStyle(.plain)
                        .font(.scaled(.subheadline))
                        .foregroundStyle(.secondary)
                        .help("Show all background work")
                        .accessibilityIdentifier("sidebar.backgroundActivity.more")
                        .popover(isPresented: $showingAll, arrowEdge: .trailing) {
                            BackgroundActivityList(activities: monitor.activities) { destination in
                                showingAll = false
                                app.openBackgroundActivity(destination)
                            }
                        }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .lbGroupedSurface()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("sidebar.backgroundActivity")
        }
    }
}

private struct BackgroundActivityList: View {
    let activities: [BackgroundActivity]
    let open: (BackgroundActivity.Destination) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("In progress").font(.scaled(.headline))
            ForEach(activities) { activity in
                BackgroundActivityButton(activity: activity, open: open)
                if activity.id != activities.last?.id { Divider() }
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}

private struct BackgroundActivityButton: View {
    let activity: BackgroundActivity
    let open: (BackgroundActivity.Destination) -> Void

    var body: some View {
        if let destination = activity.destination {
            Button { open(destination) } label: { BackgroundActivityRow(activity: activity) }
                .buttonStyle(.plain)
                .help("Open")
        } else {
            BackgroundActivityRow(activity: activity)
        }
    }
}

private struct BackgroundActivityRow: View {
    let activity: BackgroundActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: activity.kind.systemImage)
                    .foregroundStyle(Brand.teal)
                    .accessibilityHidden(true)
                Text(activity.title)
                    .font(.scaled(.callout).weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if activity.fraction == nil {
                    ProgressView().controlSize(.mini)
                }
            }
            Text(activity.detail)
                .font(.scaled(.subheadline))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let fraction = activity.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .tint(Brand.teal)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(activity.fraction.map { "\(Int(($0 * 100).rounded())) percent" } ?? "")
    }
}
