import SwiftUI

/// One operational view across activity, screen context, meeting audio,
/// processing, retention, routines, permissions, and local storage.
struct MemoryHealthSection: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject private var permissions = PermissionManager.shared
    @State private var refreshTick = 0
    @State private var storageBytes: UInt64?
    @State private var availableBytes: Int64?

    var body: some View {
        let audio = app.recording.memoryHealthSnapshot()
        let capture = captureItems
        let meetingAudio = audioItems(audio)
        let background = backgroundItems
        Group {
        Section("Memory health") {
            MemoryHealthSummary(attention: (capture + meetingAudio + background).filter { $0.tone == .attention })
            ForEach(capture) { MemoryHealthRow(item: $0) }
        }
        Section("Meeting audio") {
            ForEach(meetingAudio) { MemoryHealthRow(item: $0) }
        }
        Section("Background work") {
            ForEach(background) { MemoryHealthRow(item: $0) }

            if let error = activeError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Brand.error)
                    .textSelection(.enabled)
            }

            HStack {
                Button("Restart memory capture") { app.restartMemoryCapture() }
                Button("Run retention now") { app.screenshots.pruneOldScreenshots() }
                Spacer()
                Text("Updates every 2 seconds")
                    .font(WorkspaceTypography.metadata)
                    .settingsSecondary()
            }
            SettingsHelp("Meeting recording and autocomplete take priority over OCR, embeddings, and routines, which catch up when those tasks are idle.")
        }
        }
        .task {
            permissions.startPolling()
            defer { permissions.stopPolling() }
            await refreshStorage()
            while !Task.isCancelled {
                refreshTick &+= 1
                if refreshTick.isMultiple(of: 15) { await refreshStorage() }
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
            }
        }
    }

    private var latestActivity: Date? {
        _ = refreshTick
        return [app.sampler.lastSampleAt, app.activityStore.latestActivityEnd()]
            .compactMap { $0 }
            .max()
    }

    private var activityStatus: String {
        if !app.settings.trackingEnabled { return "Off" }
        if app.sampler.isPaused { return "Paused" }
        return ActivitySampler.hasAccessibility ? "Healthy" : "App names only"
    }

    private var accessibilityStatus: String {
        guard app.settings.trackingEnabled, app.settings.effectiveScreenContextCaptureMode.capturesText else { return "Off" }
        guard !app.sampler.isPaused else { return "Paused" }
        return AppPermission.accessibility.isGranted ? "Healthy" : "Permission needed"
    }

    private var visualStatus: String {
        guard app.settings.trackingEnabled, app.settings.effectiveScreenContextCaptureMode.capturesPixels else { return "Off" }
        guard !app.sampler.isPaused else { return "Paused" }
        return AppPermission.screenRecording.isGranted ? "Encrypted" : "Text-only fallback"
    }

    private var missingPermissions: [AppPermission] {
        var needed: Set<AppPermission> = [.microphone]
        if app.settings.trackingEnabled
            || app.settings.effectiveScreenContextCaptureMode.capturesText
            || app.settings.cotypingEnabled
            || app.settings.dictationEnabled {
            needed.insert(.accessibility)
        }
        if app.settings.cotypingEnabled || app.settings.dictationEnabled {
            needed.insert(.inputMonitoring)
        }
        if app.settings.effectiveScreenContextCaptureMode.capturesPixels {
            needed.insert(.screenRecording)
        }
        return AppPermission.allCases.filter {
            needed.contains($0) && permissions.granted[$0] != true
        }
    }

    private var routineStatus: String {
        guard app.settings.memoryRoutinesEnabled else { return "Off" }
        if app.memoryRoutines.isRunning {
            return app.memoryRoutines.currentKind.map { "Running \($0.displayName)" } ?? "Running"
        }
        return "\(app.memoryRoutines.pendingCount) pending"
    }

    private var activeError: String? {
        app.screenshots.lastError
            ?? app.screenshots.lastRetentionError
            ?? app.memoryRoutines.lastError
    }

    private var captureItems: [MemoryHealthItem] {
        [
            MemoryHealthItem(
                title: "Activity",
                icon: "clock.arrow.circlepath",
                value: activityStatus,
                detail: dateDetail(latestActivity),
                tone: MemoryHealthTone.status(activityStatus, good: ["Healthy"], idle: ["Off", "Paused"])),
            MemoryHealthItem(
                title: "Accessible text",
                icon: "text.viewfinder",
                value: accessibilityStatus,
                detail: dateDetail(app.screenshots.lastAccessibilityCapture),
                tone: MemoryHealthTone.status(accessibilityStatus, good: ["Healthy"], idle: ["Off", "Paused"])),
            MemoryHealthItem(
                title: "Visual context",
                icon: "rectangle.inset.filled.and.person.filled",
                value: visualStatus,
                detail: dateDetail(app.screenshots.lastVisualCapture),
                tone: MemoryHealthTone.status(visualStatus, good: ["Encrypted"], idle: ["Off", "Paused"])),
            MemoryHealthItem(
                title: "Local OCR",
                icon: "doc.text.viewfinder",
                value: app.screenshots.lastTextSource ?? "Waiting",
                detail: dateDetail(app.screenshots.lastOCRCapture),
                tone: app.screenshots.lastTextSource == nil ? .idle : .good),
            MemoryHealthItem(
                title: "Permissions",
                icon: "lock.shield",
                value: missingPermissions.isEmpty ? "Healthy" : "\(missingPermissions.count) needed",
                detail: missingPermissions.isEmpty
                    ? "All enabled features are authorized"
                    : missingPermissions.map(\.title).joined(separator: ", "),
                tone: missingPermissions.isEmpty ? .good : .attention),
        ]
    }

    private func audioItems(_ audio: RecordingMemoryHealthSnapshot) -> [MemoryHealthItem] {
        var items = [
            MemoryHealthItem(
                title: "Your microphone",
                icon: "mic",
                value: audio.microphoneStatus,
                detail: audioDetail(
                    date: audio.microphoneLastWriteAt,
                    dropped: audio.microphoneDroppedBuffers),
                tone: .audio(audio.microphoneStatus)),
            MemoryHealthItem(
                title: "Other side (system audio)",
                icon: "waveform",
                value: audio.systemAudioStatus,
                detail: audioDetail(
                    date: audio.systemAudioLastWriteAt,
                    dropped: audio.systemAudioDroppedBuffers),
                tone: .audio(audio.systemAudioStatus)),
        ]
        if let recovery = audio.lastRecoveryAt {
            items.append(MemoryHealthItem(
                title: "Last audio recovery",
                icon: "arrow.clockwise.heart",
                value: recovery.formatted(.relative(presentation: .named)),
                detail: recovery.formatted(date: .abbreviated, time: .standard),
                tone: .neutral))
        }
        return items
    }

    private var backgroundItems: [MemoryHealthItem] {
        [
            MemoryHealthItem(
                title: "Processing queue",
                icon: "list.bullet.rectangle",
                value: "\(app.pipelineJobStore.pendingJobs().count) pending",
                detail: app.pipeline.hasActiveWork ? "Processing now" : "Idle",
                tone: app.pipeline.hasActiveWork ? .good : .idle),
            MemoryHealthItem(
                title: "Routines",
                icon: "calendar.badge.clock",
                value: routineStatus,
                detail: dateDetail(app.memoryRoutines.lastRunAt),
                tone: !app.settings.memoryRoutinesEnabled ? .idle
                    : app.memoryRoutines.isRunning ? .good : .idle),
            MemoryHealthItem(
                title: "Retention",
                icon: "trash.slash",
                value: app.screenshots.lastRetentionError == nil ? "Healthy" : "Needs attention",
                detail: dateDetail(app.screenshots.lastRetentionRun),
                tone: app.screenshots.lastRetentionError == nil ? .good : .attention),
            MemoryHealthItem(
                title: "Local library",
                icon: "externaldrive",
                value: byteCount(storageBytes),
                detail: availableBytes.map { "\(byteCount(UInt64(max(0, $0)))) available" },
                tone: .neutral),
        ]
    }

    private func audioDetail(date: Date?, dropped: Int) -> String? {
        var values: [String] = []
        if let date { values.append("last write " + date.formatted(.relative(presentation: .named))) }
        if dropped > 0 { values.append("\(dropped) dropped buffers") }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    private func dateDetail(_ date: Date?) -> String? {
        date.map { $0.formatted(.relative(presentation: .named)) }
    }

    private func byteCount(_ bytes: UInt64?) -> String {
        guard let bytes else { return "Calculating…" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    private func refreshStorage() async {
        let root = app.storage.rootURL
        let result = await Task.detached(priority: .utility) {
            let manager = FileManager.default
            let keys: Set<URLResourceKey> = [
                .isRegularFileKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey,
            ]
            var total: UInt64 = 0
            if let enumerator = manager.enumerator(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                while let url = enumerator.nextObject() as? URL {
                    guard let values = try? url.resourceValues(forKeys: keys),
                          values.isRegularFile == true else { continue }
                    let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0
                    total &+= UInt64(max(0, size))
                }
            }
            let available = try? root.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage
            return (total, available)
        }.value
        guard !Task.isCancelled else { return }
        storageBytes = result.0
        availableBytes = result.1
    }
}

/// How a memory-health value reads at a glance: running as intended, needing
/// the user, deliberately off or waiting, or a plain measurement.
enum MemoryHealthTone: Equatable {
    case good
    case attention
    case idle
    case neutral

    /// Status strings outside both lists are unexpected, so they ask for a look.
    static func status(_ value: String, good: Set<String>, idle: Set<String>) -> Self {
        if good.contains(value) { return .good }
        if idle.contains(value) { return .idle }
        return .attention
    }

    /// Meeting audio: only live input is good; quiet states between meetings
    /// are idle; stalls, recovery, degradation, and a missing tap need a look.
    static func audio(_ status: String) -> Self {
        Self.status(status, good: ["Receiving audio"], idle: ["Idle", "Silent", "Waiting for audio"])
    }
}

struct MemoryHealthItem: Identifiable {
    var id: String { title }
    let title: String
    let icon: String
    let value: String
    let detail: String?
    let tone: MemoryHealthTone
}

/// Title and when it last happened on the left; a toned status on the right.
private struct MemoryHealthRow: View {
    let item: MemoryHealthItem

    var body: some View {
        LabeledContent {
            MemoryHealthStatus(value: item.value, tone: item.tone)
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                    if let detail = item.detail, !detail.isEmpty {
                        Text(detail)
                            .font(WorkspaceTypography.metadata)
                            .settingsSecondary()
                    }
                }
            } icon: {
                Image(systemName: item.icon).foregroundStyle(Brand.teal)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A status capsule shared by health readouts: the dot carries the tone and
/// the text keeps its meaning without color.
struct MemoryHealthStatus: View {
    @Environment(\.colorScheme) private var scheme
    let value: String
    let tone: MemoryHealthTone

    var body: some View {
        if tone == .neutral {
            Text(value)
                .font(WorkspaceTypography.metadataEmphasis.monospacedDigit())
                .settingsSecondary()
        } else {
            HStack(spacing: 6) {
                StatusDot(color: dotColor, size: 7)
                Text(value)
                    .font(WorkspaceTypography.metadataEmphasis)
                    .foregroundStyle(tone == .attention ? SettingsPalette.warning(scheme) : Color.primary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(dotColor.opacity(tone == .idle ? 0.10 : 0.14), in: Capsule())
        }
    }

    private var dotColor: Color {
        switch tone {
        case .good: Brand.teal
        case .attention: Brand.amber
        case .idle, .neutral: Color.secondary
        }
    }
}

/// One line at the top of Advanced that answers "is everything working?"
private struct MemoryHealthSummary: View {
    let attention: [MemoryHealthItem]

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            IconTile(systemImage: attention.isEmpty ? "checkmark.seal" : "exclamationmark.triangle",
                     tint: attention.isEmpty ? Brand.tealFill : Color(nsColor: .systemOrange),
                     size: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(attention.isEmpty
                     ? "Memory capture is working"
                     : "\(CountLabel.format(attention.count, "item")) \(attention.count == 1 ? "needs" : "need") attention")
                    .font(WorkspaceTypography.bodyEmphasis)
                Text(attention.isEmpty
                     ? "Capture, audio, and background work are running as configured."
                     : attention.map(\.title).joined(separator: " · "))
                    .font(WorkspaceTypography.metadata)
                    .settingsSecondary()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.memoryHealth.summary")
    }
}
