import LokalBotCompanionKit
import SwiftUI
import UIKit

/// Recording a meeting: the time, a level that shows the microphone is
/// hearing, a name, and Stop. It stays up until the recording ends, and carries
/// on with the screen locked.
struct RecordingScreen: View {
    @Environment(RecordingModel.self) private var recording
    @Environment(CompanionSession.self) private var session
    @State private var confirmingDiscard = false

    var body: some View {
        NavigationStack {
            Group {
                if recording.microphoneDenied {
                    microphoneDenied
                } else {
                    content
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !recording.isActive {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { recording.isPresented = false }
                    }
                }
            }
        }
        .interactiveDismissDisabled(recording.isActive)
        // Asked here rather than at a pause, when nobody is looking.
        .task { await QueuedAnswerNotification.requestPermission() }
    }

    private var microphoneDenied: some View {
        ContentUnavailableView {
            Label("Microphone access is off", systemImage: "mic.slash")
        } description: {
            Text("LokalBot needs the microphone to record meetings. Turn it on in Settings.")
        } actions: {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                Link("Open Settings", destination: url).primaryActionButton()
            }
        }
    }

    private var content: some View {
        @Bindable var recording = recording
        return ScrollView {
            VStack(spacing: 24) {
                statusLine
                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                    VStack(spacing: 18) {
                        Text(LBFormat.stamp(recording.elapsed))
                            .font(.system(size: 64, weight: .light, design: .rounded).monospacedDigit())
                            .accessibilityLabel("Recorded \(LBFormat.meetingDuration(recording.elapsed))")
                        LevelMeter(level: recording.phase == .recording ? recording.level : 0)
                            .frame(height: 44)
                            .accessibilityHidden(true)
                    }
                }
                TextField("Name this recording (optional)", text: $recording.title)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.done)
                VStack(spacing: 8) {
                    Text("Let everyone know you're recording.")
                    if let manifest = session.manifest, manifest.recordingsEnabled != true {
                        Text("\(session.macName) isn't set to accept recordings yet. This one stays on this device until it is.")
                    }
                    if let message = recording.errorMessage {
                        Text(message).foregroundStyle(LBTokens.Palette.attentionText)
                    }
                }
                .font(LBTokens.Typography.secondary)
                .foregroundStyle(LBTokens.Palette.supporting)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                actions
            }
            .padding(24)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .confirmationDialog("Discard this recording?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard Recording", role: .destructive) { Task { await recording.discard() } }
        } message: {
            Text("It hasn't been sent anywhere, so it can't be recovered.")
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch recording.phase {
        case .recording:
            Label("Recording", systemImage: "circle.fill")
                .foregroundStyle(LBTokens.Palette.recordingText)
                .font(LBTokens.Typography.body.weight(.semibold))
        case .interrupted:
            Label("Paused while another app uses the microphone", systemImage: "pause.circle")
                .foregroundStyle(LBTokens.Palette.attentionText)
                .font(LBTokens.Typography.secondary.weight(.semibold))
                .multilineTextAlignment(.center)
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder private var actions: some View {
        VStack(spacing: 12) {
            if recording.phase == .interrupted {
                Button {
                    recording.resume()
                } label: {
                    Label("Resume", systemImage: "mic").frame(maxWidth: .infinity)
                }
                .primaryActionButton()
                .controlSize(.large)
            }
            if recording.isActive {
                Button {
                    Task { await recording.stop() }
                } label: {
                    Label("Stop and Send", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(LBTokens.Palette.recording)
                .controlSize(.large)
                Button("Discard", role: .destructive) { confirmingDiscard = true }
            }
        }
    }
}

/// The microphone's level as a row of bars, quiet at the edges.
private struct LevelMeter: View {
    let level: Float
    private let bars = 24

    var body: some View {
        GeometryReader { proxy in
            HStack(alignment: .center, spacing: 4) {
                ForEach(0..<bars, id: \.self) { index in
                    let edge = 1 - abs(Double(index) - Double(bars - 1) / 2) / (Double(bars) / 2)
                    let height = max(4, proxy.size.height * Double(level) * (0.35 + 0.65 * edge))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(level > 0 ? Brand.tealFill : LBTokens.Palette.supporting.opacity(0.3))
                        .frame(height: height)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
            .animation(.linear(duration: 0.1), value: level)
        }
    }
}

/// Starts a recording, or returns to the one that's running. Only with a
/// paired computer, because that is the only place it can go.
struct RecordToolbarItem: ToolbarContent {
    @Environment(CompanionSession.self) private var session
    @Environment(RecordingModel.self) private var recording

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if session.mode == .paired {
                Button {
                    Task { await recording.begin() }
                } label: {
                    Label(recording.isActive ? "Recording" : "Record",
                          systemImage: recording.isActive ? "record.circle.fill" : "mic")
                }
                .tint(recording.isActive ? LBTokens.Palette.recording : nil)
            }
        }
    }
}

/// After the Mac removed this device: recordings it hadn't received yet, which
/// exist nowhere else. Pairing again sends them.
struct HeldRecordingsNotice: View {
    @Environment(CompanionSession.self) private var session
    @State private var confirmingDelete = false

    var body: some View {
        let held = session.recordings.filter(\.isOnlyCopy)
        if !held.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(held.count) recording\(held.count == 1 ? " hasn't" : "s haven't") reached a computer")
                    .font(LBTokens.Typography.body.weight(.semibold))
                Text("Pair with your computer to send \(held.count == 1 ? "it" : "them"). Until then \(held.count == 1 ? "it stays" : "they stay") on this device.")
                    .font(LBTokens.Typography.secondary)
                    .workspaceSupportingForeground()
                    .fixedSize(horizontal: false, vertical: true)
                Button("Delete \(held.count == 1 ? "It" : "Them")", role: .destructive) { confirmingDelete = true }
                    .font(LBTokens.Typography.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lbGroupedSurface()
            .confirmationDialog("Delete \(held.count == 1 ? "this recording" : "these recordings")?",
                                isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    Task { for item in held { await session.discardRecording(id: item.id) } }
                }
            } message: {
                Text("They haven't reached a computer, so they can't be recovered.")
            }
        }
    }
}

/// Recordings on this device, above the Mac's meetings, until their meeting
/// arrives from the computer.
struct DeviceRecordingsSection: View {
    @Environment(CompanionSession.self) private var session
    @State private var discarding: RecordingItem?
    @State private var renaming: RecordingItem?
    @State private var name = ""

    var body: some View {
        if !session.recordings.isEmpty {
            Section {
                ForEach(session.recordings) { item in
                    RecordingRow(item: item, progress: item.state == .waiting ? session.uploadProgress[item.id] : nil)
                        .swipeActions(edge: .trailing) {
                            if item.state != .recording {
                                Button(role: .destructive) {
                                    discarding = item
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                        .contextMenu { menu(for: item) }
                }
            } header: {
                SectionHeader("From This Device")
            }
            .confirmationDialog("Delete this recording?", isPresented: Binding(get: { discarding != nil }, set: { if !$0 { discarding = nil } }),
                                titleVisibility: .visible, presenting: discarding) { item in
                Button("Delete Recording", role: .destructive) { Task { await session.discardRecording(id: item.id) } }
            } message: { item in
                Text(item.isOnlyCopy ? "It hasn't reached \(session.macName), so it can't be recovered."
                     : "\(session.macName) keeps its copy.")
            }
            .alert("Name This Recording", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
                   presenting: renaming) { item in
                TextField("Name", text: $name)
                Button("Save") {
                    Task {
                        try? await session.store.setRecordingTitle(id: item.id, title: name)
                        await session.recordingsDidChange()
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    @ViewBuilder private func menu(for item: RecordingItem) -> some View {
        if item.state == .waiting || item.state == .failed {
            Button {
                name = item.title
                renaming = item
            } label: {
                Label("Rename", systemImage: "pencil")
            }
        }
        if item.state == .failed {
            Button {
                Task { await session.retryRecording(id: item.id) }
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
            }
        }
        if item.state != .recording {
            Button(role: .destructive) {
                discarding = item
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

/// One recording and where it stands.
struct RecordingRow: View {
    @Environment(CompanionSession.self) private var session
    @Environment(RecordingModel.self) private var recording
    let item: RecordingItem
    let progress: Double?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(item.state == .failed ? LBTokens.Palette.attentionText : Brand.teal)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title.isEmpty ? "Recording" : item.title)
                    .font(LBTokens.Typography.body.weight(.semibold))
                    .lineLimit(2)
                Text(detail)
                    .font(LBTokens.Typography.secondary)
                    .foregroundStyle(LBTokens.Palette.supporting)
                    .lineLimit(1)
                Text(stateText)
                    .font(LBTokens.Typography.caption)
                    .foregroundStyle(item.state == .failed ? LBTokens.Palette.attentionText : LBTokens.Palette.supporting)
                    .fixedSize(horizontal: false, vertical: true)
                if let progress {
                    ProgressView(value: progress).tint(Brand.tealFill)
                }
                if item.state == .failed {
                    Button("Try Again") { Task { await session.retryRecording(id: item.id) } }
                        .font(LBTokens.Typography.secondary)
                        .buttonStyle(.borderless)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch item.state {
        case .recording: "record.circle"
        case .waiting: "clock"
        case .failed: "exclamationmark.triangle"
        case .uploaded: "checkmark.circle"
        }
    }

    private var detail: String {
        let format = LBFormat.current
        return ([format.time(item.startedAt), item.durationSeconds.map(LBFormat.stamp)]
            .compactMap { $0 }).joined(separator: " · ")
    }

    private var stateText: String {
        switch item.state {
        case .recording:
            return "Recording"
        case .waiting:
            if let progress { return "Sending… \(Int(progress * 100))%" }
            return item.message ?? "Waiting for \(session.macName)"
        case .failed:
            return item.message ?? "\(session.macName) couldn't use this recording."
        case .uploaded:
            return "Processing on \(session.macName)"
        }
    }
}
