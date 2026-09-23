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
        Section("Memory Health") {
            healthRow(
                "Activity",
                icon: "clock.arrow.circlepath",
                value: activityStatus,
                detail: dateDetail(latestActivity))
            healthRow(
                "Accessible text",
                icon: "text.viewfinder",
                value: accessibilityStatus,
                detail: dateDetail(app.screenshots.lastAccessibilityCapture))
            healthRow(
                "Visual context",
                icon: "rectangle.inset.filled.and.person.filled",
                value: visualStatus,
                detail: dateDetail(app.screenshots.lastVisualCapture))
            healthRow(
                "Local OCR",
                icon: "doc.text.viewfinder",
                value: app.screenshots.lastTextSource ?? "Waiting",
                detail: dateDetail(app.screenshots.lastOCRCapture))
            healthRow(
                "Permissions",
                icon: "lock.shield",
                value: missingPermissions.isEmpty ? "Healthy" : "\(missingPermissions.count) needed",
                detail: missingPermissions.isEmpty
                    ? "All enabled features are authorized"
                    : missingPermissions.map(\.title).joined(separator: ", "))

            Divider()
            healthRow(
                "Me audio",
                icon: "mic",
                value: audio.microphoneStatus,
                detail: audioDetail(
                    date: audio.microphoneLastWriteAt,
                    dropped: audio.microphoneDroppedBuffers))
            healthRow(
                "Them audio",
                icon: "waveform",
                value: audio.systemAudioStatus,
                detail: audioDetail(
                    date: audio.systemAudioLastWriteAt,
                    dropped: audio.systemAudioDroppedBuffers))
            if let recovery = audio.lastRecoveryAt {
                healthRow(
                    "Last audio recovery",
                    icon: "arrow.clockwise.heart",
                    value: recovery.formatted(.relative(presentation: .named)),
                    detail: recovery.formatted(date: .abbreviated, time: .standard))
            }

            Divider()
            healthRow(
                "Processing queue",
                icon: "list.bullet.rectangle",
                value: "\(app.pipelineJobStore.pendingJobs().count) pending",
                detail: app.pipeline.hasActiveWork ? "Processing now" : "Idle")
            healthRow(
                "Routines",
                icon: "calendar.badge.clock",
                value: routineStatus,
                detail: dateDetail(app.memoryRoutines.lastRunAt))
            healthRow(
                "Retention",
                icon: "trash.slash",
                value: app.screenshots.lastRetentionError == nil ? "Healthy" : "Needs attention",
                detail: dateDetail(app.screenshots.lastRetentionRun))
            healthRow(
                "Local library",
                icon: "externaldrive",
                value: byteCount(storageBytes),
                detail: availableBytes.map { "\(byteCount(UInt64(max(0, $0)))) available" })

            if let error = activeError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(WorkspaceTypography.editorialBody)
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
            Text("Meeting recording and autocomplete generation take priority over OCR, embeddings, and routines. Automatic background work catches up when those interactive tasks are idle.")
                .font(WorkspaceTypography.editorialBody)
                .foregroundStyle(.secondary)
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

    private func healthRow(
        _ title: String,
        icon: String,
        value: String,
        detail: String?
    ) -> some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 1) {
                Text(value)
                    .foregroundStyle(.secondary)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(WorkspaceTypography.metadata)
                        .settingsSecondary()
                }
            }
        } label: {
            Label(title, systemImage: icon)
        }
        .accessibilityElement(children: .combine)
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
