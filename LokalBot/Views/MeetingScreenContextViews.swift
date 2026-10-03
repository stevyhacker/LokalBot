import SwiftUI

/// Documents, pages, and windows the user had on screen while the meeting
/// recorded. The thumbnail opens the retained capture in Timeline, the time
/// plays the recording from when it first appeared, and a page whose address
/// was captured can be reopened in the browser.
struct MeetingScreenMaterialsSection: View {
    let context: MeetingScreenContext
    let onPlay: (MeetingScreenContext.Material) -> Void
    let onOpen: (MeetingScreenContext.Material) -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        WorkspaceSection(title: "On Screen During the Meeting", icon: "rectangle.on.rectangle") {
            VStack(spacing: 0) {
                ForEach(context.materials) { material in
                    HStack(alignment: .center, spacing: 12) {
                        Button {
                            onPlay(material)
                        } label: {
                            Text(Transcript.stamp(material.firstOffset))
                                .font(.scaled(.callout).monospacedDigit())
                        }
                        .buttonStyle(.workspaceLink)
                        .help("Play the recording from when this first appeared")
                        .accessibilityLabel("Play from \(Transcript.stamp(material.firstOffset))")
                        Button {
                            onOpen(material)
                        } label: {
                            ScreenThumbnailView(snapshotID: material.firstSnapshotID, height: 46)
                                .frame(width: 74)
                        }
                        .buttonStyle(.plain)
                        .help("Open this capture in Timeline")
                        .accessibilityLabel("Open capture of \(material.title)")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(material.title)
                                .lineLimit(2)
                                .textSelection(.enabled)
                            Text(Self.detail(material))
                                .font(.scaled(.callout))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if let url = material.pageURL {
                            Button("Open Page") { openURL(url) }
                                .buttonStyle(.workspaceLink)
                                .help(url.absoluteString)
                                .accessibilityLabel("Open \(material.title) in the browser")
                        }
                    }
                    .padding(.vertical, 6)
                    if material.id != context.materials.last?.id { Divider() }
                }
            }
            Text("From screen memory on this Mac. Time on screen is estimated from captures, "
                + "which follow your screen retention setting.")
                .font(.scaled(.callout))
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("meeting.onScreen")
    }

    /// "Gmail · 4 min on screen"; the source is left out when the title
    /// already names it (an app with one window).
    static func detail(_ material: MeetingScreenContext.Material) -> String {
        let source = material.site ?? material.app
        let minutes = Int((material.secondsOnScreen / 60).rounded())
        let duration = switch minutes {
        case ..<1: "under a minute on screen"
        case ..<60: "\(minutes) min on screen"
        default: "\(minutes / 60) hr \(minutes % 60) min on screen"
        }
        guard source.caseInsensitiveCompare(material.title) != .orderedSame else {
            return duration.prefix(1).uppercased() + duration.dropFirst()
        }
        return "\(source) · \(duration)"
    }
}

/// A one-line strip above the transcript that follows the playhead and
/// shows which window was on screen at that point in the call.
struct MeetingOnScreenNowBar: View {
    let context: MeetingScreenContext
    @ObservedObject var player: MeetingPlayer
    let onOpen: (MeetingScreenContext.Moment) -> Void
    @State private var moment: MeetingScreenContext.Moment?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.on.rectangle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            if let moment {
                VStack(alignment: .leading, spacing: 1) {
                    Text("On screen at \(Transcript.stamp(moment.offset))")
                        .font(.scaled(.callout))
                        .foregroundStyle(.secondary)
                    Text(moment.isCall ? "The call" : moment.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text(moment.site ?? moment.app)
                    .font(.scaled(.callout))
                    .foregroundStyle(.secondary)
                Button("Open Capture") { onOpen(moment) }
                    .buttonStyle(.workspaceLink)
            } else {
                Text("Play or select a transcript line to see what was on screen.")
                    .font(.scaled(.callout))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .lbGroupedSurface()
        .onReceive(player.clock.$currentTime.map { context.moment(at: $0)?.snapshotID }.removeDuplicates()) { id in
            moment = id.flatMap { id in context.moments.first { $0.snapshotID == id } }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("meeting.onScreenNow")
    }
}
