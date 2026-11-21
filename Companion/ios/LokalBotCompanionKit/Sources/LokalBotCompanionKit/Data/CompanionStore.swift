import Foundation

public protocol CompanionStore: Sendable {
    func manifest() async throws -> Manifest?
    func meetings(fromDay: String?, toDay: String?, limit: Int) async throws -> [Meeting]
    func newestMeetings(limit: Int) async throws -> MeetingsPage
    func meeting(id: String) async throws -> Meeting?
    func transcript(meetingID: String) async throws -> Transcript?
    func days(limit: Int) async throws -> [String]
    func day(_ date: String) async throws -> DayRecord?
    func actions(_ filter: ActionFilter) async throws -> [ActionRow]
    func people() async throws -> [Person]
    func person(id: String) async throws -> Person?
    func projects() async throws -> [Project]
    func project(id: String) async throws -> Project?
    func search(_ query: String, limit: Int) async throws -> [SearchHit]

    func setActionStatus(meetingID: String, actionID: String, status: ActionStatus) async throws

    func ask(_ request: AskRequest, extraAddresses: [String],
             onDelta: @escaping @Sendable (String) -> Void) async throws -> AskResult
    func queueQuestion(_ request: AskRequest) async throws
    func queuedQuestions() async throws -> [AskRequest]
    func askHistory(limit: Int) async throws -> [AskExchange]

    func beginRecording(title: String?) async throws -> RecordingItem
    func finishRecording(id: String, durationSeconds: Double) async throws -> RecordingItem
    func recoverRecordings() async throws
    func discardRecording(id: String) async throws
    func setRecordingTitle(id: String, title: String) async throws
    func retryRecording(id: String) async throws
    func recordings() async throws -> [RecordingItem]
    func uploadRecordings(extraAddresses: [String],
                          onProgress: @escaping @Sendable (_ id: String, _ sent: Int64, _ total: Int64) -> Void) async throws -> UploadReport

    func pair(payload: String) async throws -> PairedMac
    func pairedMac() async throws -> PairedMac?
    func sync(extraAddresses: [String]) async throws -> SyncReport
    func unpair() async throws
    func status() async throws -> SyncStatus

    func loadSampleLibrary() async throws
    func isSample() async -> Bool
}

public enum CompanionStoreError: Error, Equatable, LocalizedError {
    case notPaired
    case unreachable
    case interrupted
    case pairingRejected
    case pairingExpired
    case revoked
    case pairingUnavailable
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notPaired: "This device isn't paired with a computer."
        case .unreachable: "Your computer isn't reachable right now. It needs to be awake, with sharing on, on the same Wi-Fi or on Tailscale."
        case .interrupted: "The connection to your computer dropped, but it's still answering. The answer appears here when you come back."
        case .pairingRejected: "Your computer didn't allow this device."
        case .pairingExpired: "This pairing code has expired. Show a new one on your computer."
        case .revoked: "Your computer removed this device, so its copy was erased."
        case .pairingUnavailable: "Pairing isn't available in this build. Try the sample library instead."
        case .failed(let message): message
        }
    }
}
