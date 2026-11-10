import Foundation
import Observation

/// The app's link to its store: whether it is paired, sample or neither, the
/// sync state the status pill shows, and a revision every screen reloads on.
@MainActor @Observable
public final class CompanionSession {
    public enum Mode: Equatable, Sendable {
        case loading
        /// Neither paired nor showing the sample library: the welcome screen.
        case unpaired
        case sample
        case paired
    }

    public private(set) var store: any CompanionStore
    public private(set) var mode: Mode = .loading
    public private(set) var status: SyncStatus = .unpaired
    public private(set) var pairedMac: PairedMac?
    public private(set) var manifest: Manifest?
    /// Bumped after anything that can change what screens show.
    public private(set) var revision = 0
    public private(set) var isSyncing = false
    /// The last sync failed because no address answered.
    public private(set) var macUnreachable = false
    public private(set) var lastSyncError: String?
    /// One-off messages for the user, such as being removed by the Mac.
    public var notice: String?
    /// Recordings on this device or just sent, newest first.
    public private(set) var recordings: [RecordingItem] = []
    public private(set) var isUploading = false
    /// How far each recording being sent has got, from 0 to 1.
    public private(set) var uploadProgress: [String: Double] = [:]
    /// Request ids being asked right now, so a queued one isn't asked twice at once.
    var askingIDs: Set<String> = []
    /// One pass over the queued questions at a time, so a second sync doesn't
    /// announce an answer the first is about to.
    private var answeringQueued = false

    /// Bonjour results as `host:port`, preferring the paired Mac. Set by the app.
    public var discoverAddresses: @MainActor () async -> [String] = { [] }
    /// Called when a queued question is answered after the Mac comes back.
    public var onQueuedAnswer: @MainActor (AskRequest, AskResult) -> Void = { _, _ in }
    /// Asks the system for time to finish an upload; the result gives it back.
    public var holdWhileUploading: @MainActor () -> (@MainActor () -> Void) = { {} }

    public init(store: any CompanionStore) {
        self.store = store
    }

    /// "Today" for every screen. The sample library keeps the day it was made,
    /// so it reads the same whenever it is opened.
    public var referenceDate: Date {
        referenceDateOverride ?? (mode == .sample ? SampleLibrary.referenceDate : Date())
    }

    /// Pins "today" for previews and screenshots.
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

    // MARK: Lifecycle

    /// Reads pairing and sample state; call at launch.
    public func start() async {
        // Nothing can be recording yet, so anything marked so was cut short.
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

    /// Switches to a store opened again, for example with a new device name
    /// before pairing.
    public func replaceStore(_ store: any CompanionStore) async {
        self.store = store
        await refresh()
    }

    // MARK: Sync

    /// Connects, sends queued changes, catches up and answers queued questions.
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
        // An answer can take minutes. The sync is over by now, so a change made
        // meanwhile is sent at once instead of waiting for it.
        await answerQueuedQuestions(addresses: addresses)
    }

    /// Questions asked while the Mac was away, or whose connection dropped
    /// while it answered. A question Ask is asking right now is left to it.
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

    // MARK: Recordings

    /// Sends what's waiting. Whatever doesn't get through stays waiting for
    /// the next sync, so failing here needs no message beyond the row's own.
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
                    // A report can land after the pass that sent it has ended.
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
            // Unreachable, or the connection dropped: the next sync resumes it.
        }
        await recordingsDidChange()
        // The Mac makes a meeting of it; fetch that as soon as it's published.
        if uploaded > 0 { await syncNow() }
    }

    /// Reloads the list after a change the store can't announce.
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

    // MARK: Changes

    public func setActionStatus(_ status: ActionStatus, meetingID: String, actionID: String) async throws {
        try await store.setActionStatus(meetingID: meetingID, actionID: actionID, status: status)
        revision += 1
        if mode == .paired {
            Task { await syncNow() }
        }
    }

    // MARK: Pairing

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

    /// Erases the local copy, recordings that haven't arrived and the pairing.
    /// This is local only (ffi.md `unpair`), so the device also needs removing
    /// from the Mac's list.
    public func removeThisDevice() async {
        try? await store.unpair()
        macUnreachable = false
        lastSyncError = nil
        await refresh()
    }
}
