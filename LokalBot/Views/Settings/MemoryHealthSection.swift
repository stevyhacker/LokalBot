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
            HStack(alignment: .center, spacing: 12) {
                MemoryHealthSummary(attention: (capture + meetingAudio + background).filter { $0.tone == .attention })
                Spacer(minLength: 12)
                Button("Restart memory capture") { app.restartMemoryCapture() }
            }
            MemoryHealthTable(items: capture)
        }
        Section("Meeting audio") {
            MemoryHealthTable(items: meetingAudio)
        }
        Section("Background work") {
            MemoryHealthTable(items: background)

            if let error = activeError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.scaledSystem(size: 12))
                    .foregroundStyle(Brand.error)
                    .textSelection(.enabled)
            }

            HStack(alignment: .center, spacing: 16) {
                SettingsHelp("Meeting recording and autocomplete take priority over OCR, embeddings, and routines, which catch up when those tasks are idle.")
                Spacer(minLength: 0)
                Button("Run retention now") { app.screenshots.pruneOldScreenshots() }
            }
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
                value: app.screenshots.lastTextSource.map(Self.textSourceLabel) ?? "Waiting",
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

    /// "hybrid_redacted" → "Hybrid, redacted", so the status reads like its neighbours.
    static func textSourceLabel(_ source: String) -> String {
        let redacted = source.hasSuffix("_redacted")
        let base = redacted ? String(source.dropLast("_redacted".count)) : source
        let label = switch base {
        case "accessibility": "Accessibility"
        case "hybrid": "Hybrid"
        case "ocr": "OCR"
        default: base.prefix(1).uppercased() + base.dropFirst()
        }
        return redacted ? label + ", redacted" : label
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

/// Health rows in aligned columns: symbol, name, when it last happened, and
/// status. One grid keeps the columns straight whatever the text lengths;
/// each row reads to assistive technology as one element on its name.
private struct MemoryHealthTable: View {
    let items: [MemoryHealthItem]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 9) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Divider().gridCellUnsizedAxes(.horizontal)
                }
                GridRow(alignment: .firstTextBaseline) {
                    Image(systemName: item.icon)
                        .foregroundStyle(Brand.teal)
                        .frame(width: 20)
                        .accessibilityHidden(true)
                    // A shared minimum lines the detail column up across sections.
                    Text(item.title)
                        .fixedSize()
                        .frame(minWidth: 130, alignment: .leading)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(item.title)
                        .accessibilityValue([item.value, item.detail].compactMap { $0 }.joined(separator: ", "))
                    Text(item.detail ?? "")
                        .font(AppFont.scaled(.callout))
                        .settingsSecondary()
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityHidden(true)
                    MemoryHealthStatus(value: item.value, tone: item.tone)
                        .gridColumnAlignment(.trailing)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// A status shared by health readouts: a toned dot and a word, the word
/// keeping its meaning without color. Only states that need the user get a
/// filled capsule, so a healthy page stays quiet.
struct MemoryHealthStatus: View {
    @Environment(\.colorScheme) private var scheme
    let value: String
    let tone: MemoryHealthTone

    var body: some View {
        switch tone {
        case .neutral:
            Text(value)
                .font(AppFont.scaled(.callout).weight(.medium).monospacedDigit())
                .settingsSecondary()
        case .attention:
            HStack(spacing: 6) {
                StatusDot(color: Brand.amber, size: 7)
                Text(value)
                    .font(AppFont.scaled(.callout).weight(.semibold))
                    .foregroundStyle(SettingsPalette.warning(scheme))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Brand.amber.opacity(0.14), in: Capsule())
        case .good, .idle:
            HStack(spacing: 6) {
                StatusDot(color: tone == .good ? Brand.teal : Color.secondary.opacity(0.6), size: 7)
                Text(value)
                    .font(AppFont.scaled(.callout))
                    .settingsSecondary()
            }
        }
    }
}

/// One line at the top of Advanced that answers "is everything working?"
private struct MemoryHealthSummary: View {
    let attention: [MemoryHealthItem]

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            IconTile(systemImage: attention.isEmpty ? "checkmark.seal" : "exclamationmark.triangle",
                     tint: attention.isEmpty ? Brand.teal : LBTokens.Palette.attentionText,
                     size: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(attention.isEmpty
                     ? "Memory capture is working"
                     : "\(CountLabel.format(attention.count, "item")) \(attention.count == 1 ? "needs" : "need") attention")
                    .font(AppFont.scaled(.body).weight(.semibold))
                Text(attention.isEmpty
                     ? "Capture, audio, and background work are running as configured."
                     : attention.map(\.title).joined(separator: " · "))
                    .font(AppFont.scaled(.callout))
                    .settingsSecondary()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.memoryHealth.summary")
    }
}
