import Foundation

/// One remote attendee from the calendar event matched to a meeting.
///
/// The email address is retained only in local meeting metadata so the rename
/// UI can distinguish attendees with the same display name. Transcript aliases
/// persist the opaque `id`, never the email address.
struct CalendarParticipantIdentity: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String?
    let emailAddress: String?

    /// An editable picker suggestion, never an automatic speaker identity.
    /// EventKit often supplies an address without a display name. Keep that
    /// absence in metadata so automatic naming cannot treat this guess as fact.
    var suggestedSpeakerName: String? {
        if let name { return name }
        guard let address = emailAddress,
              let localPart = address.split(separator: "@").first?.split(separator: "+").first else { return nil }
        let words = localPart.split(whereSeparator: { ".-_".contains($0) })
        guard (1...4).contains(words.count),
              words.allSatisfy({ (1...24).contains($0.count) && $0.allSatisfy(\.isLetter) }) else { return nil }
        let mailbox = words.joined().lowercased()
        let sharedMailboxes: Set<String> = [
            "admin", "all", "calendar", "contact", "events", "hello", "info", "mail",
            "noreply", "notifications", "office", "reception", "room", "sales", "support", "team",
            "me", "you", "everyone", "presentation", "presenting", "sharedroom"
        ]
        guard !sharedMailboxes.contains(mailbox) else { return nil }
        return Self.normalizedDisplayName(words.map { String($0).capitalized }.joined(separator: " "))
    }

    init?(id: String = UUID().uuidString, name: String?, emailAddress: String?) {
        let normalizedName = name.flatMap(Self.normalizedDisplayName)
        let normalizedEmail = emailAddress.flatMap(Self.normalizedEmailAddress)
        guard normalizedName != nil || normalizedEmail != nil else { return nil }

        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = trimmedID.isEmpty ? UUID().uuidString : trimmedID
        self.name = normalizedName
        self.emailAddress = normalizedEmail
    }

    /// EventKit represents attendee addresses as participant URLs. Accept only
    /// `mailto:` so opaque calendar/provider identifiers are never mistaken for
    /// email addresses.
    static func emailAddress(from participantURL: URL?) -> String? {
        guard let participantURL,
              participantURL.scheme?.caseInsensitiveCompare("mailto") == .orderedSame else {
            return nil
        }
        let prefixLength = "mailto:".count
        let absolute = participantURL.absoluteString
        guard absolute.count >= prefixLength else { return nil }
        let encodedAddress = absolute.dropFirst(prefixLength)
            .split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? ""
        let address = encodedAddress.removingPercentEncoding ?? encodedAddress
        return normalizedEmailAddress(address)
    }

    static func normalizedEmailAddress(_ raw: String) -> String? {
        let email = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (3...254).contains(email.count),
              email.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return nil
        }
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return email
    }

    /// Deduplicates identities by email first and by name only when an email is
    /// unavailable. A same-name/different-email pair remains distinct.
    static func normalized(_ identities: [CalendarParticipantIdentity])
        -> [CalendarParticipantIdentity] {
        var result: [CalendarParticipantIdentity] = []

        for input in identities {
            guard let identity = CalendarParticipantIdentity(
                id: input.id,
                name: input.name,
                emailAddress: input.emailAddress) else { continue }

            if let email = identity.emailAddress,
               let index = result.firstIndex(where: { $0.emailAddress == email }) {
                result[index] = merged(result[index], identity)
                continue
            }

            if let nameKey = identity.name.map(normalizedNameKey) {
                let matchingNameIndices = result.indices.filter {
                    result[$0].name.map(normalizedNameKey) == nameKey
                }
                if identity.emailAddress != nil,
                   let nameOnlyIndex = matchingNameIndices.first(where: {
                       result[$0].emailAddress == nil
                   }) {
                    result[nameOnlyIndex] = merged(result[nameOnlyIndex], identity)
                    continue
                }
                if identity.emailAddress == nil, matchingNameIndices.count == 1,
                   let existingIndex = matchingNameIndices.first {
                    result[existingIndex] = merged(result[existingIndex], identity)
                    continue
                }
            }

            result.append(identity)
        }
        return result
    }

    static func fromLegacyNames(_ names: [String]) -> [CalendarParticipantIdentity] {
        normalized(names.compactMap {
            guard let name = normalizedDisplayName($0) else { return nil }
            return CalendarParticipantIdentity(
                id: "legacy-name:\(normalizedNameKey(name))",
                name: name,
                emailAddress: nil)
        })
    }

    private static func merged(
        _ first: CalendarParticipantIdentity,
        _ second: CalendarParticipantIdentity
    ) -> CalendarParticipantIdentity {
        CalendarParticipantIdentity(
            id: first.id,
            name: first.name ?? second.name,
            emailAddress: first.emailAddress ?? second.emailAddress) ?? first
    }

    private static func normalizedNameKey(_ name: String) -> String {
        name.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current)
    }

    private static func normalizedDisplayName(_ raw: String) -> String? {
        var name = raw
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        name = name.replacingOccurrences(
            of: #"(?i)\s*\((host|co-host|organizer|presenter|you|me)\)\s*"#,
            with: " ",
            options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard (2...80).contains(name.count),
              name.rangeOfCharacter(from: .letters) != nil,
              !name.contains("@"),
              !name.lowercased().contains("http") else {
            return nil
        }
        return name
    }
}
