import Foundation

enum CotypingDebouncePolicy {
    enum RuntimeProfile: Equatable, Sendable {
        case inProcess
        case modelServer
    }

    static let minimumMilliseconds = 20
    static let maxBackoffMilliseconds = 600

    static func milliseconds(
        lastLatencyMilliseconds: Int?,
        configured: Int,
        profile: RuntimeProfile = .modelServer,
        consumedDelayMilliseconds: Int = 0
    ) -> Int {
        let fallback = max(minimumMilliseconds, configured)
        let total: Int
        switch profile {
        case .inProcess:
            guard let last = lastLatencyMilliseconds, last > 0 else {
                return max(0, fallback - max(0, consumedDelayMilliseconds))
            }
            switch last {
            case ...70: total = minimumMilliseconds
            case ...140: total = 25
            default: total = 55
            }
        case .modelServer:
            if let last = lastLatencyMilliseconds, last > 0 {
                total = max(fallback, min(last / 2, maxBackoffMilliseconds))
            } else {
                total = fallback
            }
        }
        return max(0, total - max(0, consumedDelayMilliseconds))
    }
}
