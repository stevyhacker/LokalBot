import Foundation

/// How the phone reached the Mac, from the address the last sync used:
/// Tailscale's ranges and MagicDNS names, otherwise the local network.
public enum NetworkRoute: String, Sendable, Hashable {
    case localNetwork
    case tailscale

    public var label: String {
        switch self {
        case .localNetwork: "Wi-Fi"
        case .tailscale: "Tailscale"
        }
    }

    public var systemImage: String {
        switch self {
        case .localNetwork: "wifi"
        case .tailscale: "point.3.connected.trianglepath.dotted"
        }
    }

    /// `address` is `host`, `host:port` or `[v6]:port`.
    public init?(address: String?) {
        guard let host = address.map(Self.host(of:)), !host.isEmpty else { return nil }
        self = Self.isTailscale(host) ? .tailscale : .localNetwork
    }

    static func host(of address: String) -> String {
        if address.hasPrefix("["), let close = address.firstIndex(of: "]") {
            return String(address[address.index(after: address.startIndex)..<close])
        }
        let colons = address.filter { $0 == ":" }.count
        if colons == 1, let colon = address.lastIndex(of: ":") { return String(address[..<colon]) }
        return address
    }

    static func isTailscale(_ host: String) -> Bool {
        let lower = host.lowercased()
        if lower.hasSuffix(".ts.net") || lower.hasSuffix(".ts.net.") { return true }
        if lower.hasPrefix("fd7a:115c:a1e0:") { return true }
        let octets = lower.split(separator: ".").compactMap { UInt8($0) }
        // 100.64.0.0/10
        return octets.count == 4 && octets[0] == 100 && (64...127).contains(octets[1])
    }
}
