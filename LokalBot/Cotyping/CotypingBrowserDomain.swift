// Contains code ported from Cotabby (https://github.com/FuJacob/cotabby),
// copyright the Cotabby authors, under the GNU AGPL v3.0
// (LICENSES/AGPL-3.0.txt). Modified for LokalBot since 23 June 2026.
// See THIRD_PARTY_NOTICES.md.

import Foundation

enum CotypingBrowserDomain {
    static func hasConfiguredExclusions(_ excludedDomains: [String]) -> Bool {
        excludedDomains.contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    static func host(fromURLString urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let host = components.host, !host.isEmpty
        else { return nil }
        return stripLeadingWWW(host.lowercased())
    }

    static func isHostDisabled(_ host: String?, excludedDomains: [String]) -> Bool {
        guard let host, !host.isEmpty else { return false }
        for entry in excludedDomains {
            guard let domain = normalize(entry) else { continue }
            if host == domain || host.hasSuffix("." + domain) { return true }
        }
        return false
    }

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
