import Foundation

/// Makes the local/remote boundary explicit for user-configured inference
/// servers. Loopback endpoints stay zero-friction; any other host must be
/// approved before transcripts, screen text, or agent context can be sent.
enum InferenceEndpointPolicy {

    enum PolicyError: LocalizedError, Equatable {
        case unsupportedURL
        case insecureRemoteEndpoint(String)
        case remoteApprovalRequired(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedURL:
                "Use an http or https inference-server URL."
            case .insecureRemoteEndpoint(let origin):
                "Remote inference server \(origin) is not encrypted. Use HTTPS, or run the server on this Mac."
            case .remoteApprovalRequired(let origin):
                "Approve the remote inference server \(origin) under Settings → Models before sending meeting or workday text to it."
            }
        }
    }

    static func origin(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        // URLComponents.host rejects a bare IPv6 literal even though URL.host
        // correctly returns one (for example, "::1"). Render the authority
        // directly so loopback and approved remote IPv6 origins stay canonical.
        let authority = host.contains(":") ? "[\(host)]" : host
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(authority)\(port)"
    }

    static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        // "0.0.0.0" is deliberately NOT loopback: it's the unspecified
        // address, and treating it as local would silently trust a
        // nonstandard destination. Local servers should use localhost or
        // 127.0.0.1 — which is also where a 0.0.0.0-bound server listens.
        return host == "localhost"
            || host.hasSuffix(".localhost")
            || host == "::1"
            || host == "0:0:0:0:0:0:0:1"
            || isIPv4Loopback(host)
    }

    static func requiresApproval(_ url: URL) -> Bool {
        origin(for: url) != nil && !isLoopback(url)
    }

    /// A host on the user's own network rather than the internet: a private
    /// (RFC 1918), link-local or Tailscale (100.64.0.0/10) IPv4 address, an
    /// IPv6 unique-local or link-local address, or a name only such a network
    /// resolves (`.local`, `.home.arpa`, a Tailscale `.ts.net` name, or a
    /// single-label name such as a MagicDNS short name). Judged from the URL
    /// alone; loopback is not included, it has its own rule.
    static func isPrivateNetwork(_ url: URL) -> Bool {
        guard let rawHost = url.host?.lowercased(), !rawHost.isEmpty, !isLoopback(url) else { return false }
        // An IPv6 zone ("fe80::1%en0") names the interface, not the host.
        let host = rawHost.split(separator: "%", maxSplits: 1).first.map(String.init) ?? rawHost
        if host.contains(":") { return isPrivateIPv6(host) }
        if let octets = ipv4Octets(host) { return isPrivateIPv4(octets) }
        let name = host.hasSuffix(".") ? String(host.dropLast()) : host
        guard !name.isEmpty else { return false }
        return !name.contains(".")
            || privateNetworkSuffixes.contains { name.hasSuffix($0) }
    }

    /// Whether a request may use plain `http://` to `url`: always for
    /// loopback, and for a private-network host only when the caller opts in.
    static func permitsUnencrypted(_ url: URL, allowsPrivateNetworkHTTP: Bool) -> Bool {
        isLoopback(url) || (allowsPrivateNetworkHTTP && isPrivateNetwork(url))
    }

    static func isAllowed(_ url: URL, approvedOrigins: [String],
                          allowsPrivateNetworkHTTP: Bool = false) -> Bool {
        guard let origin = origin(for: url) else { return false }
        if isLoopback(url) { return true }
        let transportAllowed = url.scheme?.lowercased() == "https"
            || permitsUnencrypted(url, allowsPrivateNetworkHTTP: allowsPrivateNetworkHTTP)
        return transportAllowed && approvedOrigins.contains(origin)
    }

    static func validate(_ url: URL, approvedOrigins: [String],
                         allowsPrivateNetworkHTTP: Bool = false) throws {
        guard let origin = origin(for: url) else { throw PolicyError.unsupportedURL }
        if isLoopback(url) { return }
        guard url.scheme?.lowercased() == "https"
                || permitsUnencrypted(url, allowsPrivateNetworkHTTP: allowsPrivateNetworkHTTP) else {
            throw PolicyError.insecureRemoteEndpoint(origin)
        }
        guard approvedOrigins.contains(origin) else {
            throw PolicyError.remoteApprovalRequired(origin)
        }
    }

    /// Name suffixes that public DNS never answers: mDNS, the RFC 8375 home
    /// network domain, and Tailscale MagicDNS.
    private static let privateNetworkSuffixes = [".local", ".home.arpa", ".ts.net"]

    private static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var values: [Int] = []
        values.reserveCapacity(4)
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber),
                  let value = Int(part), (0...255).contains(value) else { return nil }
            values.append(value)
        }
        return values
    }

    private static func isPrivateIPv4(_ octets: [Int]) -> Bool {
        switch (octets[0], octets[1]) {
        case (10, _): true                          // 10.0.0.0/8
        case (172, 16...31): true                   // 172.16.0.0/12
        case (192, 168): true                       // 192.168.0.0/16
        case (169, 254): true                       // link-local, e.g. a USB network
        case (100, 64...127): true                  // 100.64.0.0/10, Tailscale addresses
        default: false
        }
    }

    private static func isPrivateIPv6(_ host: String) -> Bool {
        guard let first = host.split(separator: ":", omittingEmptySubsequences: false).first,
              !first.isEmpty, first.count <= 4,
              let hextet = UInt16(first, radix: 16) else { return false }
        return hextet & 0xFE00 == 0xFC00            // fc00::/7 unique local, incl. Tailscale
            || hextet & 0xFFC0 == 0xFE80            // fe80::/10 link-local
    }

    private static func isIPv4Loopback(_ host: String) -> Bool {
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        var values: [Int] = []
        values.reserveCapacity(4)
        for octet in octets {
            guard !octet.isEmpty,
                  octet.allSatisfy(\.isNumber),
                  let value = Int(octet), (0...255).contains(value) else {
                return false
            }
            values.append(value)
        }
        return values[0] == 127
    }
}
