import Foundation

/// The parts of Gmail API responses LokalBot reads
/// (developers.google.com/workspace/gmail/api/reference/rest, 2026-10).
struct GmailProfile: Decodable, Equatable, Sendable {
    var emailAddress: String
    var historyId: String
}

struct GmailSendAsList: Decodable, Sendable {
    struct SendAs: Decodable, Sendable {
        var sendAsEmail: String
        var verificationStatus: String?
    }

    var sendAs: [SendAs]?

    /// Verified "Send mail as" addresses, lowercased. Gmail leaves the
    /// status out for the primary address.
    var addresses: [String] {
        (sendAs ?? []).compactMap { entry in
            guard entry.verificationStatus == nil || entry.verificationStatus == "accepted" else { return nil }
            return entry.sendAsEmail.lowercased()
        }
    }
}

struct GmailThreadList: Decodable, Sendable {
    struct Entry: Decodable, Sendable {
        var id: String
    }

    var threads: [Entry]?
    var nextPageToken: String?
}

struct GmailHistoryList: Decodable, Sendable {
    struct MessageRef: Decodable, Sendable {
        var id: String
        var threadId: String
    }

    struct Change: Decodable, Sendable {
        struct Wrapped: Decodable, Sendable {
            var message: MessageRef
            /// The labels a `labelsAdded` or `labelsRemoved` entry changed.
            var labelIds: [String]?
        }

        var messages: [MessageRef]?
        var messagesAdded: [Wrapped]?
        var messagesDeleted: [Wrapped]?
        var labelsAdded: [Wrapped]?
        var labelsRemoved: [Wrapped]?

        /// Threads this change touched in a way that can change whether they
        /// qualify. Reading, starring, or archiving mail changes labels too,
        /// but never the answer, so those threads aren't fetched again.
        var threadIDs: Set<String> {
            var ids: Set<String> = []
            for group in [messagesAdded, messagesDeleted] {
                for entry in group ?? [] { ids.insert(entry.message.threadId) }
            }
            for group in [labelsAdded, labelsRemoved] {
                for entry in group ?? [] where Self.changesQualification(entry.labelIds ?? []) {
                    ids.insert(entry.message.threadId)
                }
            }
            return ids
        }

        static func changesQualification(_ labels: [String]) -> Bool {
            labels.contains { label in
                EmailScope.excludedLabels.contains(label) || label == "SENT"
                    || EmailScope.bulkCategories.contains(label)
            }
        }
    }

    var history: [Change]?
    var nextPageToken: String?
    var historyId: String?
}

struct GmailThreadResource: Decodable, Equatable, Sendable {
    var id: String
    var messages: [GmailMessageResource]?
}

struct GmailMessageResource: Decodable, Equatable, Sendable {
    var id: String
    var threadId: String
    var labelIds: [String]?
    /// Milliseconds since 1970, as a decimal string.
    var internalDate: String?
    var payload: GmailMessagePart?

    var labels: Set<String> { Set(labelIds ?? []) }

    var date: Date? {
        guard let internalDate, let milliseconds = Double(internalDate) else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }

    /// The first value of a top-level header, case-insensitively.
    func header(_ name: String) -> String? {
        payload?.header(name)
    }
}

struct GmailMessagePart: Decodable, Equatable, Sendable {
    struct Header: Decodable, Equatable, Sendable {
        var name: String
        var value: String
    }

    struct Body: Decodable, Equatable, Sendable {
        var size: Int?
        /// base64url; absent for attachments, which Gmail serves separately.
        var data: String?
        var attachmentId: String?
    }

    var mimeType: String?
    var filename: String?
    var headers: [Header]?
    var body: Body?
    var parts: [GmailMessagePart]?

    func header(_ name: String) -> String? {
        headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var lowercasedMimeType: String { (mimeType ?? "").lowercased() }

    var isAttachment: Bool {
        if let filename, !filename.isEmpty { return true }
        if let disposition = header("Content-Disposition")?.lowercased(),
           disposition.hasPrefix("attachment") { return true }
        return body?.attachmentId != nil && !lowercasedMimeType.hasPrefix("text/")
    }

    /// The decoded text of this part in its declared charset.
    var decodedText: String? {
        guard let data = body?.data, let bytes = ChatGPTPlanOAuth.base64URLDecode(Substring(data)) else {
            return nil
        }
        return EmailText.decode(bytes, charset: EmailText.charset(fromContentType: header("Content-Type")))
    }
}
