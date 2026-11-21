import Foundation
import Observation

@MainActor @Observable
public final class CompanionSession {
    public enum Mode: Equatable, Sendable {
        case loading
        case unpaired
        case sample
        case paired
    }

    public private(set) var store: any CompanionStore
    public private(set) var mode: Mode = .loading
    public private(set) var status: SyncStatus = .unpaired
    public private(set) var pairedMac: PairedMac?
    public private(set) var manifest: Manifest?
    public private(set) var revision = 0
    public private(set) var isSyncing = false
    public private(set) var macUnreachable = false
    public private(set) var lastSyncError: String?
    public var notice: String?
    public private(set) var recordings: [RecordingItem] = []
    public private(set) var isUploading = false
    public private(set) var uploadProgress: [String: Double] = [:]
    var askingIDs: Set<String> = []
    private var answeringQueued = false

    public var discoverAddresses: @MainActor () async -> [String] = { [] }
    public var onQueuedAnswer: @MainActor (AskRequest, AskResult) -> Void = { _, _ in }
    public var holdWhileUploading: @MainActor () -> (@MainActor () -> Void) = { {} }

    public init(store: any CompanionStore) {
        self.store = store
    }

    public var referenceDate: Date {
        referenceDateOverride ?? (mode == .sample ? SampleLibrary.referenceDate : Date())
    }

    public var referenceDateOverride: Date?

    public var today: DayKey { DayKey(referenceDate) }

    public var presentation: SyncPresentation {
        switch mode {
        case .loading, .unpaired: return .notPaired
        case .sample: return .sample
        case .paired:
            if isSyncing { return .syncing(lastSync: status.lastSyncAt) }
            if macUnreachable { return .unreachable(lastSync: status.lastSyncAt) }
            if let lastSyncError { return .failed(message: lastSyncError, lastSync: status.lastSyncAt) }
            guard let last = status.lastSyncAt else { return .neverSynced }
            return .synced(at: last, route: NetworkRoute(address: status.lastAddress))
        }
    }

    public var macName: String {
        pairedMac?.macName ?? status.macName ?? manifest?.macName ?? "your computer"
    }

    public func start() async {
        try? await store.recoverRecordings()
        await refresh()
    }

    public func refresh() async {
        status = (try? await store.status()) ?? .unpaired
        pairedMac = try? await store.pairedMac()
        manifest = try? await store.manifest()
        recordings = (try? await store.recordings()) ?? []
        if status.paired {
            mode = .paired
        } else if await store.isSample() {
            mode = .sample
        } else {
            mode = .unpaired
        }
        revision += 1
    }

    public func replaceStore(_ store: any CompanionStore) async {
        self.store = store
        await refresh()
    }

    public func syncNow() async {
        guard mode == .paired, !isSyncing else { return }
        isSyncing = true
        let addresses = await discoverAddresses()
        var synced = false
        do {
            _ = try await store.sync(extraAddresses: addresses)
            macUnreachable = false
            lastSyncError = nil
            await refresh()
            synced = true
        } catch CompanionStoreError.unreachable {
            macUnreachable = true
            status = (try? await store.status()) ?? status
        } catch CompanionStoreError.revoked {
            notice = CompanionStoreError.revoked.errorDescription
            await refresh()
        } catch {
            lastSyncError = error.localizedDescription
        }
        isSyncing = false
        guard synced else { return }
        Task { await uploadRecordings() }
        await answerQueuedQuestions(addresses: addresses)
    }

    private func answerQueuedQuestions(addresses: [String]) async {
        guard !answeringQueued else { return }
        answeringQueued = true
        defer { answeringQueued = false }
        guard let queued = try? await store.queuedQuestions(), !queued.isEmpty else { return }
        for request in queued where !askingIDs.contains(request.requestId) {
            askingIDs.insert(request.requestId)
            defer { askingIDs.remove(request.requestId) }
            guard let result = try? await store.ask(request, extraAddresses: addresses, onDelta: { _ in }) else { break }
            onQueuedAnswer(request, result)
        }
        revision += 1
    }

    public func uploadRecordings() async {
        guard mode == .paired, !isUploading, recordings.contains(where: { $0.state == .waiting }) else { return }
        isUploading = true
        let release = holdWhileUploading()
        defer {
            isUploading = false
            uploadProgress = [:]
            release()
        }
        let addresses = await discoverAddresses()
        var uploaded = 0
        do {
            let report = try await store.uploadRecordings(extraAddresses: addresses) { id, sent, total in
                Task { @MainActor [weak self] in
                    guard let self, self.isUploading else { return }
                    self.uploadProgress[id] = total > 0 ? Double(sent) / Double(total) : 0
                }
            }
            uploaded = report.uploaded
        } catch CompanionStoreError.revoked {
            notice = CompanionStoreError.revoked.errorDescription
            await refresh()
            return
        } catch {
        }
        await recordingsDidChange()
        if uploaded > 0 { await syncNow() }
    }

    public func recordingsDidChange() async {
        recordings = (try? await store.recordings()) ?? recordings
        revision += 1
    }

    public func retryRecording(id: String) async {
        try? await store.retryRecording(id: id)
        await recordingsDidChange()
        await uploadRecordings()
    }

    public func discardRecording(id: String) async {
        try? await store.discardRecording(id: id)
        await recordingsDidChange()
    }

    public func setActionStatus(_ status: ActionStatus, meetingID: String, actionID: String) async throws {
        try await store.setActionStatus(meetingID: meetingID, actionID: actionID, status: status)
        revision += 1
        if mode == .paired {
            Task { await syncNow() }
        }
    }

    public func pair(payload: String) async throws -> PairedMac {
        let mac = try await store.pair(payload: payload)
        await refresh()
        Task { await syncNow() }
        return mac
    }

    public func showSampleLibrary() async throws {
        try await store.loadSampleLibrary()
        await refresh()
    }

    public func removeThisDevice() async {
        try? await store.unpair()
        macUnreachable = false
        lastSyncError = nil
        await refresh()
    }
}
