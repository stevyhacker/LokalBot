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

    /// Bonjour results as `host:port`, preferring the paired Mac. Set by the app.
    public var discoverAddresses: @MainActor () async -> [String] = { [] }
    /// Called when a queued question is answered after the Mac comes back.
    public var onQueuedAnswer: @MainActor (AskRequest, AskResult) -> Void = { _, _ in }

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
        pairedMac?.macName ?? status.macName ?? manifest?.macName ?? "your Mac"
    }

    // MARK: Lifecycle

    /// Reads pairing and sample state; call at launch.
    public func start() async {
        await refresh()
    }

    public func refresh() async {
        status = (try? await store.status()) ?? .unpaired
        pairedMac = try? await store.pairedMac()
        manifest = try? await store.manifest()
        if status.paired {
            mode = .paired
        } else if await store.isSample() {
            mode = .sample
        } else {
            mode = .unpaired
        }
        revision += 1
    }

    /// Something changed in the store; every screen reloads.
    public func storeDidChange() {
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
        defer { isSyncing = false }
        let addresses = await discoverAddresses()
        do {
            _ = try await store.sync(extraAddresses: addresses)
            macUnreachable = false
            lastSyncError = nil
            await refresh()
            await answerQueuedQuestions(addresses: addresses)
        } catch CompanionStoreError.unreachable {
            macUnreachable = true
            status = (try? await store.status()) ?? status
        } catch CompanionStoreError.revoked {
            notice = CompanionStoreError.revoked.errorDescription
            await refresh()
        } catch {
            lastSyncError = error.localizedDescription
        }
    }

    private func answerQueuedQuestions(addresses: [String]) async {
        guard let queued = try? await store.queuedQuestions(), !queued.isEmpty else { return }
        for request in queued {
            guard let result = try? await store.ask(request, extraAddresses: addresses, onDelta: { _ in }) else { break }
            onQueuedAnswer(request, result)
        }
        revision += 1
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

    /// Erases the local copy and the pairing. This is local only (ffi.md
    /// `unpair`), so the device also needs removing from the Mac's list.
    public func removeThisDevice() async {
        try? await store.unpair()
        macUnreachable = false
        lastSyncError = nil
        await refresh()
    }
}
