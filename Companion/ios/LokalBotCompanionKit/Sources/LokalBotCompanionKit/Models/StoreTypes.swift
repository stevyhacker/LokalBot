import Foundation

/// An action with its meeting, as the store lists it (ffi.md, ActionRow).
public struct ActionRow: Codable, Sendable, Hashable, Identifiable {
    public var meetingId: String
    public var meetingTitle: String
    public var meetingStartedAt: Date
    public var action: ActionItem
    /// A status change made here that the Mac hasn't confirmed yet.
    public var pending: Bool
    /// The computer didn't make the last status change sent from here.
    public var syncNote: ActionSyncNote?

    public var id: String { "\(meetingId)/\(action.id)" }

    public init(meetingId: String, meetingTitle: String, meetingStartedAt: Date, action: ActionItem, pending: Bool = false,
                syncNote: ActionSyncNote? = nil) {
        self.meetingId = meetingId
        self.meetingTitle = meetingTitle
        self.meetingStartedAt = meetingStartedAt
        self.action = action
        self.pending = pending
        self.syncNote = syncNote
    }

    /// The row for one of a meeting's own actions, which carry what a row does.
    public init(meeting: Meeting, action: ActionItem) {
        self.init(meetingId: meeting.id, meetingTitle: meeting.title, meetingStartedAt: meeting.startedAt,
                  action: action, pending: action.pending, syncNote: action.syncNote)
    }
}

/// One page of the Meetings list.
public struct MeetingsPage: Sendable, Hashable {
    public var meetings: [Meeting]
    /// Older meetings exist beyond these.
    public var hasMore: Bool

    public init(meetings: [Meeting], hasMore: Bool) {
        self.meetings = meetings
        self.hasMore = hasMore
    }

    /// From the rows a store returned when asked for `limit + 1`. A meeting
    /// this build can't read is left out, and must not look like the end of
    /// the list: whether more exist is counted in rows, not in what decoded.
    public init(rows: [String], limit: Int) {
        meetings = rows.prefix(limit).compactMap { try? CompanionJSON.decode(Meeting.self, from: $0) }
        hasMore = rows.count > limit
    }
}

/// Mirrors ffi.md `ActionFilter`.
public struct ActionFilter: Sendable, Hashable {
    public var mineOnly: Bool
    public var status: ActionStatus?
    public var ownerUnclearOnly: Bool
    /// `YYYY-MM-DD`, exclusive.
    public var dueBefore: String?

    public init(mineOnly: Bool = false, status: ActionStatus? = nil, ownerUnclearOnly: Bool = false, dueBefore: String? = nil) {
        self.mineOnly = mineOnly
        self.status = status
        self.ownerUnclearOnly = ownerUnclearOnly
        self.dueBefore = dueBefore
    }

    public static let all = ActionFilter()
    public static let myOpen = ActionFilter(mineOnly: true, status: .open)

    public func matches(_ action: ActionItem) -> Bool {
        if mineOnly && !action.ownerIsUser { return false }
        if ownerUnclearOnly && !action.ownerUnclear { return false }
        if let status, action.status != status { return false }
        if let dueBefore {
            guard let due = action.dueDate, due < dueBefore else { return false }
        }
        return true
    }
}

/// Mirrors ffi.md `SearchHit`.
public struct SearchHit: Sendable, Hashable, Identifiable {
    public var kind: String
    public var key: String
    public var meetingId: String?
    public var title: String
    public var snippet: String
    /// Segment start, for transcript hits.
    public var at: Double?
    /// `YYYY-MM-DD`, for day hits.
    public var date: String?

    public var id: String { "\(kind)/\(key)/\(at.map { String($0) } ?? "")/\(snippet.hashValue)" }

    public init(kind: String, key: String, meetingId: String? = nil, title: String, snippet: String,
                at: Double? = nil, date: String? = nil) {
        self.kind = kind
        self.key = key
        self.meetingId = meetingId
        self.title = title
        self.snippet = snippet
        self.at = at
        self.date = date
    }
}

/// Mirrors ffi.md `SyncStatus`.
public struct SyncStatus: Sendable, Hashable {
    public var paired: Bool
    public var lastSyncAt: Date?
    public var lastAddress: String?
    public var cursor: UInt64
    public var pendingOps: Int
    public var macName: String?

    public init(paired: Bool = false, lastSyncAt: Date? = nil, lastAddress: String? = nil,
                cursor: UInt64 = 0, pendingOps: Int = 0, macName: String? = nil) {
        self.paired = paired
        self.lastSyncAt = lastSyncAt
        self.lastAddress = lastAddress
        self.cursor = cursor
        self.pendingOps = pendingOps
        self.macName = macName
    }

    public static let unpaired = SyncStatus()
}

/// Mirrors ffi.md `SyncReport`.
public struct SyncReport: Sendable, Hashable {
    public var received: Int
    public var deleted: Int
    public var opsApplied: Int
    public var cursor: UInt64
    public var address: String?
    public var finishedAt: Date

    public init(received: Int = 0, deleted: Int = 0, opsApplied: Int = 0, cursor: UInt64 = 0,
                address: String? = nil, finishedAt: Date = Date()) {
        self.received = received
        self.deleted = deleted
        self.opsApplied = opsApplied
        self.cursor = cursor
        self.address = address
        self.finishedAt = finishedAt
    }
}

/// Mirrors ffi.md `RecordingInfo`: a recording this device holds or just sent.
public struct RecordingItem: Sendable, Hashable, Identifiable {
    public enum State: String, Sendable, Hashable {
        /// A recorder is writing it, or was when the app last stopped.
        case recording
        /// On its way to the Mac as soon as it can be reached.
        case waiting
        /// The Mac refused it; it stays until retried or discarded.
        case failed
        /// The Mac has it; the audio left this device.
        case uploaded
    }

    /// A UUID; the Mac's meeting has the same id.
    public var id: String
    /// Empty until the person names it.
    public var title: String
    public var state: State
    public var startedAt: Date
    public var durationSeconds: Double?
    public var byteCount: Int64
    public var sentBytes: Int64
    /// Why it hasn't reached the Mac, or what went wrong.
    public var message: String?
    /// Where the recorder writes.
    public var filePath: String

    public init(id: String, title: String = "", state: State, startedAt: Date, durationSeconds: Double? = nil,
                byteCount: Int64 = 0, sentBytes: Int64 = 0, message: String? = nil, filePath: String = "") {
        self.id = id
        self.title = title
        self.state = state
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.byteCount = byteCount
        self.sentBytes = sentBytes
        self.message = message
        self.filePath = filePath
    }

    /// Still only on this device, so deleting it loses it.
    public var isOnlyCopy: Bool { state != .uploaded }
}

/// Mirrors ffi.md `UploadReport`.
public struct UploadReport: Sendable, Hashable {
    public var uploaded: Int
    public var waiting: Int
    public var failed: Int

    public init(uploaded: Int = 0, waiting: Int = 0, failed: Int = 0) {
        self.uploaded = uploaded
        self.waiting = waiting
        self.failed = failed
    }
}

/// Mirrors ffi.md `PairedMac`.
public struct PairedMac: Sendable, Hashable {
    public var macName: String
    public var macKeyB64: String
    public var addresses: [String]
    public var port: UInt16
    public var pairedAt: Date

    public init(macName: String, macKeyB64: String, addresses: [String], port: UInt16, pairedAt: Date) {
        self.macName = macName
        self.macKeyB64 = macKeyB64
        self.addresses = addresses
        self.port = port
        self.pairedAt = pairedAt
    }
}
