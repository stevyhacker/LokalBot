import SwiftUI

struct RecordingHealthStrip: View {
    @ObservedObject var recording: RecordingController

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { context in
            let health = recording.memoryHealthSnapshot(at: context.date)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(recording.captureWarnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(LBTokens.Palette.attentionText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if recording.callObservationUnavailable {
                    Text("Browser audio is captured by process and may include other tabs in that process.")
                        .font(.scaled(.caption))
                        .foregroundStyle(.secondary)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 20) {
                        Label("Mic · \(health.microphoneStatus)", systemImage: "mic")
                        Label("System · \(health.systemAudioStatus)", systemImage: "speaker.wave.2")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Mic · \(health.microphoneStatus)", systemImage: "mic")
                        Label("System · \(health.systemAudioStatus)", systemImage: "speaker.wave.2")
                    }
                }
                if let level = health.systemAudioLevel {
                    HStack(spacing: 3) {
                        ForEach(0..<20, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Double(index) / 20 < level ? Brand.teal : Color.secondary.opacity(0.15))
                                .frame(width: 5, height: 10)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("System audio input level")
                    .accessibilityValue("\(Int(level * 100)) percent")
                }
                if let recovery = health.lastRecoveryAt {
                    Text("Last recovery \(recovery.formatted(date: .omitted, time: .standard))")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.scaled(.callout))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .lbGroupedSurface()
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("recording.health")
        }
    }
}
