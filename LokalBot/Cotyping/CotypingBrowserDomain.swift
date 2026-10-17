// Contains code ported from Cotabby (https://github.com/FuJacob/cotabby),
// copyright the Cotabby authors, under the GNU AGPL v3.0
// (LICENSES/AGPL-3.0.txt). Modified for LokalBot since 23 June 2026.
// See THIRD_PARTY_NOTICES.md.

import Foundation

/// Pure host/domain matching for per-site cotyping disable. Ported from Cotabby's
/// `BrowserDomain`: turn a focused tab's URL into a comparable host and decide
/// whether it's covered by the user's disable list. The raw URL is read over
/// Accessibility elsewhere (`CotypingAXHelper.webURL`); this stays pure and
/// trivially testable.
enum CotypingBrowserDomain {
    static func hasConfiguredExclusions(_ excludedDomains: [String]) -> Bool {
        excludedDomains.contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Lowercased host from a URL string, dropping a leading "www." so
    /// "www.bank.com" and "bank.com" compare equal. Nil for URLs with no network
    /// host (`file://`, `about:`, empty, unparseable), so non-web focus never
    /// matches a domain rule.
    static func host(fromURLString urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let host = components.host, !host.isEmpty
        else { return nil }
        return stripLeadingWWW(host.lowercased())
    }

    /// Whether `host` is covered by `excludedDomains`: an exact match, or a
    /// subdomain of a listed domain ("mail.bank.com" is disabled by "bank.com").
    /// Case- and "www."-insensitive on both sides; list entries may be pasted as
    /// full URLs. An empty/nil host or empty list never matches.
    static func isHostDisabled(_ host: String?, excludedDomains: [String]) -> Bool {
        guard let host, !host.isEmpty else { return false }
        for entry in excludedDomains {
            guard let domain = normalize(entry) else { continue }
            if host == domain || host.hasSuffix("." + domain) { return true }
        }
        return false
    }

    /// Normalizes a configured list entry like a parsed host, tolerating a full
    /// URL ("https://bank.com/login") or a bare host ("bank.com").
    private static func normalize(_ entry: String) -> String? {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let parsed = host(fromURLString: trimmed) { return parsed }
        return stripLeadingWWW(trimmed.lowercased())
    }

    private static func stripLeadingWWW(_ host: String) -> String {
        guard host.hasPrefix("www."), host.count > 4 else { return host }
        return String(host.dropFirst(4))
    }
}
