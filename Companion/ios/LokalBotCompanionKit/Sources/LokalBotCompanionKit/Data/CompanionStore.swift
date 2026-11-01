import Foundation

/// The phone's copy of the Mac's shared library and its link to the Mac. It
/// mirrors the `SyncClient` API in Companion/protocol/ffi.md: the app uses the
/// Rust-backed store, and `FixtureStore` serves the sample library and tests.
/// Lists are newest first unless a method says otherwise.
public protocol CompanionStore: Sendable {
    // Reads
    func manifest() async throws -> Manifest?
    func meetings(fromDay: String?, toDay: String?, limit: Int) async throws -> [Meeting]
    func meeting(id: String) async throws -> Meeting?
    func transcript(meetingID: String) async throws -> Transcript?
    /// Day keys that have a record.
    func days(limit: Int) async throws -> [String]
    func day(_ date: String) async throws -> DayRecord?
    /// In `ActionOrdering.sorted` order.
    func actions(_ filter: ActionFilter) async throws -> [ActionRow]
    func people() async throws -> [Person]
    func person(id: String) async throws -> Person?
    func projects() async throws -> [Project]
    func project(id: String) async throws -> Project?
    func search(_ query: String, limit: Int) async throws -> [SearchHit]

    // Changes from this device
    /// Applies the status at once, marked pending until the Mac confirms it.
    func setActionStatus(meetingID: String, actionID: String, status: ActionStatus) async throws

    // Questions
    func ask(_ request: AskRequest, extraAddresses: [String],
             onDelta: @escaping @Sendable (String) -> Void) async throws -> AskResult
    func queueQuestion(_ request: AskRequest) async throws
    func queuedQuestions() async throws -> [AskRequest]
    func askHistory(limit: Int) async throws -> [AskExchange]

    // Pairing and sync
    func pair(payload: String) async throws -> PairedMac
    func pairedMac() async throws -> PairedMac?
    func sync(extraAddresses: [String]) async throws -> SyncReport
    /// Erases the local copy and the pairing.
    func unpair() async throws
    func status() async throws -> SyncStatus

    // Sample library
    /// Replaces the local copy with the bundled sample library.
    func loadSampleLibrary() async throws
    func isSample() async -> Bool
}

public enum CompanionStoreError: Error, Equatable, LocalizedError {
    case notPaired
    /// No address answered. The phone offers to search its own copy instead.
    case unreachable
    case pairingRejected
    case pairingExpired
    /// The Mac removed this device; its copy has been erased.
    case revoked
    case pairingUnavailable
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notPaired: "This device isn't paired with a Mac."
        case .unreachable: "Your Mac isn't reachable right now. It needs to be awake, with sharing on, on the same Wi-Fi or on Tailscale."
        case .pairingRejected: "Your Mac didn't allow this device."
        case .pairingExpired: "This pairing code has expired. Show a new one on your Mac."
        case .revoked: "Your Mac removed this device, so its copy was erased."
        case .pairingUnavailable: "Pairing isn't available in this build. Try the sample library instead."
        case .failed(let message): message
        }
    }
}
