import Foundation

/// What LokalBot downloads: conversations, not inboxes. A thread qualifies
/// when the person wrote in it, or when someone on their calendar takes part
/// and the mail isn't bulk. Newsletters, receipts, and notifications never
/// qualify on the calendar rule. Spam, Trash, and Drafts are never read.
enum EmailScope {
    static let windowDays = 90
    /// A first scan stops here and says so in Settings.
    static let maxThreadsPerScan = 2_000
    static let maxBodyCharacters = 40_000
    /// Addresses per participant search, keeping each Gmail query short.
    static let addressesPerQuery = 15

    static let excludedLabels: Set<String> = ["SPAM", "TRASH", "DRAFT"]
    /// Gmail's tabs other than Primary.
    static let bulkCategories: Set<String> = [
        "CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL", "CATEGORY_UPDATES", "CATEGORY_FORUMS",
    ]

    static func windowStart(now: Date) -> Date {
        now.addingTimeInterval(-TimeInterval(windowDays) * 86_400)
    }

    // MARK: Searches

    /// Threads the person wrote in. Gmail search leaves out Spam and Trash.
    static func sentQuery(after: Date) -> String {
        "in:sent after:\(Int(after.timeIntervalSince1970))"
    }

    /// One search for a few people, and the people it covers.
    struct ParticipantSearch: Equatable, Sendable {
        var query: String
        var addresses: Set<String>
    }

    /// Threads with these people, outside Gmail's bulk tabs. The `{}` group
    /// is Gmail's OR.
    static func participantSearches(addresses: Set<String>, after: Date) -> [ParticipantSearch] {
        let searchable = addresses.filter(isSearchable).sorted()
        var searches: [ParticipantSearch] = []
        var start = 0
        while start < searchable.count {
            let chunk = searchable[start..<min(start + addressesPerQuery, searchable.count)]
            var terms: [String] = []
            for address in chunk {
                terms.append("from:\(address)")
                terms.append("to:\(address)")
                terms.append("cc:\(address)")
            }
            let query = "{\(terms.joined(separator: " "))} after:\(Int(after.timeIntervalSince1970))"
                + " -category:promotions -category:social -category:updates -category:forums"
            searches.append(ParticipantSearch(query: query, addresses: Set(chunk)))
            start += addressesPerQuery
        }
        return searches
    }

    /// Only plain addresses go into a search; anything with Gmail query
    /// syntax in it is skipped rather than escaped.
    static func isSearchable(_ address: String) -> Bool {
        guard address.contains("@"), address.count <= 254 else { return false }
        return address.allSatisfy { $0.isLetter || $0.isNumber || "@.-_+'".contains($0) }
    }

    // MARK: Who counts

    private static let automatedLocalParts: Set<String> = [
        "noreply", "no-reply", "no_reply", "donotreply", "do-not-reply", "do_not_reply",
        "mailer-daemon", "postmaster", "bounce", "bounces", "notifications", "notification",
        "notify", "alerts", "newsletter", "news", "marketing", "receipts", "invoice", "invoices",
        "calendar-notification",
    ]

    /// Mailboxes no person reads: no-reply senders, notification robots, and
    /// calendar resources (rooms, group calendars).
    static func isAutomated(_ address: String) -> Bool {
        let parts = address.lowercased().split(separator: "@", maxSplits: 1)
        guard parts.count == 2 else { return true }
        let local = String(parts[0])
        let domain = String(parts[1])
        if automatedLocalParts.contains(local) { return true }
        if local.hasPrefix("noreply") || local.hasPrefix("no-reply") || local.hasSuffix("-noreply")
            || local.hasPrefix("bounce") { return true }
        return domain.hasSuffix("calendar.google.com") || domain.hasSuffix(".bounces.google.com")
    }

    /// The people worth searching mail for: calendar attendees who are
    /// neither the person nor a robot.
    static func knownPeople(_ attendees: Set<String>, excluding owned: Set<String>) -> Set<String> {
        Set(attendees.map { $0.lowercased() }.filter { !owned.contains($0) && !isAutomated($0) && $0.contains("@") })
    }

    /// Mailing lists, newsletters, and machine-sent mail.
    static func isBulk(_ message: GmailMessageResource) -> Bool {
        if !message.labels.isDisjoint(with: bulkCategories) { return true }
        if message.header("List-Unsubscribe") != nil || message.header("List-Id") != nil { return true }
        if let precedence = message.header("Precedence")?.lowercased(),
           ["bulk", "list", "junk"].contains(precedence.trimmingCharacters(in: .whitespaces)) { return true }
        if let auto = message.header("Auto-Submitted")?.lowercased(),
           !auto.trimmingCharacters(in: .whitespaces).hasPrefix("no") { return true }
        if let from = message.header("From").flatMap(EmailText.address), isAutomated(from.address) { return true }
        return false
    }

    /// Only Gmail's SENT label proves the account wrote a message. A `From`
    /// header with the person's own address can be forged by anyone, so a
    /// spoofed message never counts as the person's words.
    static func isFromOwner(_ message: GmailMessageResource) -> Bool {
        message.labels.contains("SENT")
    }

    /// Messages LokalBot may keep from a thread: inside the window and in
    /// none of the never-read labels.
    static func keptMessages(_ thread: GmailThreadResource, windowStart: Date) -> [GmailMessageResource] {
        (thread.messages ?? []).filter { message in
            guard message.labels.isDisjoint(with: excludedLabels), let date = message.date else { return false }
            return date >= windowStart
        }
    }

    /// Decides from headers alone (a `metadata` fetch) whether a thread is
    /// downloaded. `people` are the calendar people of the window.
    static func qualifies(_ thread: GmailThreadResource, people: Set<String>, windowStart: Date) -> Bool {
        let kept = keptMessages(thread, windowStart: windowStart)
        guard !kept.isEmpty else { return false }
        if kept.contains(where: isFromOwner) { return true }
        guard !people.isEmpty else { return false }
        return kept.contains { message in
            guard !isBulk(message) else { return false }
            return !participants(of: message).isDisjoint(with: people)
        }
    }

    /// The same rule for a stored thread, after older messages aged out of
    /// it: what remains must still qualify on its own.
    static func stillQualifies(_ thread: EmailThread, people: Set<String>) -> Bool {
        if thread.messages.contains(where: \.fromMe) { return true }
        return thread.messages.contains { message in
            !message.isBulk && message.participants.contains { people.contains($0.address) }
        }
    }

    static func participants(of message: GmailMessageResource) -> Set<String> {
        var addresses: Set<String> = []
        for name in ["From", "To", "Cc"] {
            for address in EmailText.addresses(message.header(name) ?? "") {
                addresses.insert(address.address)
            }
        }
        return addresses
    }

    // MARK: Building what is stored

    /// The stored conversation from a `full` fetch, or nil when no message
    /// survives the window and label rules.
    static func thread(from resource: GmailThreadResource, accountID: UUID, windowStart: Date) -> EmailThread? {
        let messages = keptMessages(resource, windowStart: windowStart)
            .compactMap(message(from:))
            .sorted { $0.date < $1.date }
        guard let first = messages.first else { return nil }
        return EmailThread(id: resource.id, accountID: accountID, subject: first.subject, messages: messages)
    }

    static func message(from resource: GmailMessageResource) -> EmailMessage? {
        guard let date = resource.date else { return nil }
        let from = resource.header("From").flatMap(EmailText.address)
        var body = resource.payload.map(bodyText) ?? ""
        if body.count > maxBodyCharacters { body = String(body.prefix(maxBodyCharacters)) }
        return EmailMessage(
            id: resource.id,
            internetMessageID: resource.header("Message-ID")?.trimmingCharacters(in: .whitespacesAndNewlines),
            date: date,
            from: from,
            to: EmailText.addresses(resource.header("To") ?? ""),
            cc: EmailText.addresses(resource.header("Cc") ?? ""),
            subject: EmailText.decodeEncodedWords(resource.header("Subject") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            fromMe: isFromOwner(resource),
            isBulk: isBulk(resource),
            body: body,
            attachments: resource.payload.map(attachments) ?? [])
    }

    /// The first `text/plain` body, else the first `text/html` one converted.
    static func bodyText(_ part: GmailMessagePart) -> String {
        if let plain = firstText(in: part, mimeType: "text/plain") {
            return plain.replacingOccurrences(of: "\r\n", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let html = firstText(in: part, mimeType: "text/html") {
            return EmailText.plainText(fromHTML: html)
        }
        return ""
    }

    private static func firstText(in part: GmailMessagePart, mimeType: String) -> String? {
        if part.lowercasedMimeType == mimeType, !part.isAttachment, let text = part.decodedText { return text }
        for child in part.parts ?? [] {
            if let text = firstText(in: child, mimeType: mimeType) { return text }
        }
        return nil
    }

    static func attachments(_ part: GmailMessagePart) -> [EmailAttachment] {
        var found: [EmailAttachment] = []
        if part.isAttachment, let name = part.filename, !name.isEmpty {
            found.append(EmailAttachment(name: name, mimeType: part.lowercasedMimeType, size: part.body?.size ?? 0))
        }
        for child in part.parts ?? [] {
            found.append(contentsOf: attachments(child))
        }
        return found
    }
}
