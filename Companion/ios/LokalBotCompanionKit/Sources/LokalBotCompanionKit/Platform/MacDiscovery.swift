import Foundation
import Network

/// Finds LokalBot Macs on the current network: Bonjour `_lokalbot._tcp`,
/// each instance resolved to an IPv4 `host:port` for the sync core. The TXT
/// record's `k` (a short hash of the Mac's key) picks out the paired Mac;
/// the key itself proves it during the handshake.
public final class MacDiscovery: @unchecked Sendable {
    public static let serviceType = "_lokalbot._tcp"

    public struct Instance: Sendable, Hashable {
        public var name: String
        /// TXT `k`.
        public var fingerprint: String?
        public var address: String
    }

    public enum Outcome: Sendable, Equatable {
        case found([Instance])
        /// Local Network access is off for the app; Tailscale and stored
        /// addresses still work.
        case localNetworkDenied
    }

    private let queue = DispatchQueue(label: "me.dotenv.LokalBot.companion.discovery")

    public init() {}

    /// Addresses of the paired Mac first, then any instance without a `k`.
    /// Other Macs are left out.
    public func addresses(preferringFingerprint fingerprint: String?, browseSeconds: Double = 1.5) async -> [String] {
        guard case .found(let instances) = await discover(browseSeconds: browseSeconds) else { return [] }
        guard let fingerprint else { return instances.map(\.address) }
        let matching = instances.filter { $0.fingerprint == fingerprint }.map(\.address)
        let unlabeled = instances.filter { $0.fingerprint == nil }.map(\.address)
        return matching + unlabeled
    }

    public func discover(browseSeconds: Double = 1.5) async -> Outcome {
        let browse = await browse(seconds: browseSeconds)
        if browse.denied { return .localNetworkDenied }
        var instances: [Instance] = []
        for result in browse.results {
            guard case .service(let name, _, _, _) = result.endpoint,
                  let address = await resolve(result.endpoint) else { continue }
            var fingerprint: String?
            if case .bonjour(let txt) = result.metadata { fingerprint = txt["k"]?.lowercased() }
            instances.append(Instance(name: name, fingerprint: fingerprint, address: address))
        }
        return .found(instances)
    }

    private func browse(seconds: Double) async -> (results: [NWBrowser.Result], denied: Bool) {
        await withCheckedContinuation { continuation in
            let run = BrowseRun(queue: queue, continuation: continuation)
            run.start(seconds: seconds)
        }
    }

    private func resolve(_ endpoint: NWEndpoint) async -> String? {
        await withCheckedContinuation { continuation in
            let run = ResolveRun(endpoint: endpoint, queue: queue, continuation: continuation)
            run.start(timeout: 2)
        }
    }

    static func format(_ host: NWEndpoint.Host, _ port: NWEndpoint.Port) -> String? {
        switch host {
        case .ipv4(let address):
            return address.rawValue.map(String.init).joined(separator: ".") + ":\(port.rawValue)"
        case .ipv6(let address):
            let words = stride(from: 0, to: 16, by: 2).map { i in
                String(UInt16(address.rawValue[i]) << 8 | UInt16(address.rawValue[i + 1]), radix: 16)
            }
            return "[\(words.joined(separator: ":"))]:\(port.rawValue)"
        case .name(let name, _):
            return "\(name):\(port.rawValue)"
        @unknown default:
            return nil
        }
    }
}

/// One browse; every callback runs on `queue`.
private final class BrowseRun: @unchecked Sendable {
    private let queue: DispatchQueue
    private let browser = NWBrowser(for: .bonjourWithTXTRecord(type: MacDiscovery.serviceType, domain: nil), using: .tcp)
    private var continuation: CheckedContinuation<(results: [NWBrowser.Result], denied: Bool), Never>?
    private var results: [NWBrowser.Result] = []

    init(queue: DispatchQueue, continuation: CheckedContinuation<(results: [NWBrowser.Result], denied: Bool), Never>) {
        self.queue = queue
        self.continuation = continuation
    }

    func start(seconds: Double) {
        browser.browseResultsChangedHandler = { [self] results, _ in self.results = Array(results) }
        browser.stateUpdateHandler = { [self] state in
            switch state {
            // kDNSServiceErr_PolicyDenied: the Local Network permission is off.
            case .waiting(.dns(-65570)), .failed(.dns(-65570)): finish(denied: true)
            case .failed: finish(denied: false)
            default: break
            }
        }
        browser.start(queue: queue)
        queue.asyncAfter(deadline: .now() + seconds) { [self] in finish(denied: false) }
    }

    private func finish(denied: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        // The handlers keep this run alive while it browses; drop them now.
        browser.browseResultsChangedHandler = nil
        browser.stateUpdateHandler = nil
        browser.cancel()
        continuation.resume(returning: (results, denied))
    }
}

/// Opens a connection only to learn the instance's address, then closes it.
private final class ResolveRun: @unchecked Sendable {
    private let queue: DispatchQueue
    private let connection: NWConnection
    private var continuation: CheckedContinuation<String?, Never>?

    init(endpoint: NWEndpoint, queue: DispatchQueue, continuation: CheckedContinuation<String?, Never>) {
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        self.connection = NWConnection(to: endpoint, using: parameters)
        self.queue = queue
        self.continuation = continuation
    }

    func start(timeout: Double) {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                if case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint {
                    finish(MacDiscovery.format(host, port))
                } else {
                    finish(nil)
                }
            case .waiting, .failed, .cancelled: finish(nil)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { [self] in finish(nil) }
    }

    private func finish(_ address: String?) {
        guard let continuation else { return }
        self.continuation = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(returning: address)
    }
}
