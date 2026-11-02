import Foundation

/// An action with its meeting, as the store lists it (ffi.md, ActionRow).
public struct ActionRow: Codable, Sendable, Hashable, Identifiable {
    public var meetingId: String
    public var meetingTitle: String
    public var meetingStartedAt: Date
    public var action: ActionItem
    /// A status change made here that the Mac hasn't confirmed yet.
    public var pending: Bool

    public var id: String { "\(meetingId)/\(action.id)" }

    public init(meetingId: String, meetingTitle: String, meetingStartedAt: Date, action: ActionItem, pending: Bool = false) {
        self.meetingId = meetingId
        self.meetingTitle = meetingTitle
        self.meetingStartedAt = meetingStartedAt
        self.action = action
        self.pending = pending
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
