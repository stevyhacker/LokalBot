import SwiftUI

/// Documents, pages, and windows the user had on screen while the meeting
/// recorded. Titles only; opening one goes to the retained capture in
/// Timeline, and play jumps the recording to when it first appeared.
struct MeetingScreenMaterialsSection: View {
    let context: MeetingScreenContext
    let onPlay: (MeetingScreenContext.Material) -> Void
    let onOpen: (MeetingScreenContext.Material) -> Void

    var body: some View {
        WorkspaceSection(title: "On Screen During the Meeting", icon: "rectangle.on.rectangle") {
            VStack(spacing: 0) {
                ForEach(context.materials) { material in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Button {
                            onPlay(material)
                        } label: {
                            Text(Transcript.stamp(material.firstOffset))
                                .font(.callout.monospacedDigit())
                        }
                        .buttonStyle(.workspaceLink)
                        .help("Play the recording from when this first appeared")
                        .accessibilityLabel("Play from \(Transcript.stamp(material.firstOffset))")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(material.title)
                                .lineLimit(2)
                                .textSelection(.enabled)
                            Text(detail(material))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Open Capture") { onOpen(material) }
                            .buttonStyle(.workspaceLink)
                            .accessibilityLabel("Open capture of \(material.title)")
                    }
                    .padding(.vertical, 6)
                    if material.id != context.materials.last?.id { Divider() }
                }
            }
            Text("From screen memory on this Mac. Captures follow your screen retention setting.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("meeting.onScreen")
    }

    private func detail(_ material: MeetingScreenContext.Material) -> String {
        var parts = [material.host ?? material.app]
        if material.captureCount > 1 { parts.append("returned to \(material.captureCount) times") }
        return parts.joined(separator: " · ")
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
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(moment.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text(moment.app)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Open Capture") { onOpen(moment) }
                    .buttonStyle(.workspaceLink)
            } else {
                Text("Play or select a transcript line to see what was on screen.")
                    .font(.callout)
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
