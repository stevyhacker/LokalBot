import Foundation

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
        let authority = host.contains(":") ? "[\(host)]" : host
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(authority)\(port)"
    }

    static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "localhost"
            || host.hasSuffix(".localhost")
            || host == "::1"
            || host == "0:0:0:0:0:0:0:1"
            || isIPv4Loopback(host)
    }

    static func requiresApproval(_ url: URL) -> Bool {
        origin(for: url) != nil && !isLoopback(url)
    }

    static func isPrivateNetwork(_ url: URL) -> Bool {
        guard let rawHost = url.host?.lowercased(), !rawHost.isEmpty, !isLoopback(url) else { return false }
        let host = rawHost.split(separator: "%", maxSplits: 1).first.map(String.init) ?? rawHost
        if host.contains(":") { return isPrivateIPv6(host) }
        if let octets = ipv4Octets(host) { return isPrivateIPv4(octets) }
        let name = host.hasSuffix(".") ? String(host.dropLast()) : host
        guard !name.isEmpty else { return false }
        return !name.contains(".")
            || privateNetworkSuffixes.contains { name.hasSuffix($0) }
    }

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
        case (10, _): true
        case (172, 16...31): true
        case (192, 168): true
        case (169, 254): true
        case (100, 64...127): true
        default: false
        }
    }

    private static func isPrivateIPv6(_ host: String) -> Bool {
        guard let first = host.split(separator: ":", omittingEmptySubsequences: false).first,
              !first.isEmpty, first.count <= 4,
              let hextet = UInt16(first, radix: 16) else { return false }
        return hextet & 0xFE00 == 0xFC00
            || hextet & 0xFFC0 == 0xFE80
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
