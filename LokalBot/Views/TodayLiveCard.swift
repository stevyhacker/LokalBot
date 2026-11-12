import SwiftUI

/// The recording in progress, at the top of Today: what is being recorded, for
/// how long, whether sound is arriving, and the only Stop on the page.
struct TodayLiveCard: View {
    @EnvironmentObject private var app: AppState
    let meeting: Meeting

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                summary
                Spacer(minLength: 8)
                actions.fixedSize()
            }
            VStack(alignment: .leading, spacing: 12) {
                summary
                actions
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .todayCardSurface(tint: LBTokens.Palette.recording)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today.live")
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                StatusDot(color: Brand.recording, size: 7, pulses: true)
                    .accessibilityHidden(true)
                Text("Recording")
                Text(verbatim: "·").accessibilityHidden(true)
                MeetingRecordingTimerText(recording: app.recording)
            }
            .font(AppFont.scaled(.callout).weight(.semibold).monospacedDigit())
            .foregroundStyle(LBTokens.Palette.recordingText)
            .accessibilityElement(children: .combine)
            Text(verbatim: meeting.displayTitle)
                .font(TodayType.cardTitle)
                .lineLimit(1)
                .accessibilityIdentifier("today.live.title")
            TodayRecordingLevels(recording: app.recording)
                .padding(.top, 4)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Open live notes") { app.showLiveMeeting() }
                .accessibilityIdentifier("today.live.notes")
            Button {
                app.stopRecording()
            } label: {
                Label {
                    Text("Stop")
                } icon: {
                    Image(systemName: "stop.fill")
                        .foregroundStyle(LBTokens.Palette.recording)
                }
            }
            .accessibilityLabel("Stop Recording")
            .accessibilityIdentifier("today.live.stop")
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
}

/// Whether each source is producing sound right now, from the same health
/// snapshot the recording strip reads, on one line.
private struct TodayRecordingLevels: View {
    @ObservedObject var recording: RecordingController

    private static let meterBars = 10

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let health = recording.memoryHealthSnapshot(at: context.date)
            VStack(alignment: .leading, spacing: 4) {
                MeetingWrappingRow(spacing: 14, lineSpacing: 4) {
                    Label("Mic · \(health.microphoneStatus)", systemImage: "mic")
                    HStack(spacing: 6) {
                        Label("System · \(health.systemAudioStatus)", systemImage: "speaker.wave.2")
                        if let level = health.systemAudioLevel { meter(level) }
                    }
                }
                .foregroundStyle(.secondary)
                ForEach(recording.captureWarnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(LBTokens.Palette.attentionText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(AppFont.scaled(.callout))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("today.live.health")
        }
    }

    private func meter(_ level: Double) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<Self.meterBars, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Double(index) / Double(Self.meterBars) < level
                          ? LBTokens.Palette.accentFill : Color.secondary.opacity(0.2))
                    .frame(width: 4, height: 9)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("System audio input level")
        .accessibilityValue(Text(Int(level * 100), format: .percent))
    }
}
