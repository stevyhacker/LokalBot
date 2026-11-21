import Foundation

struct CotypingFocusPollBackoff: Sendable {
    private(set) var idleCaptureCount = 0

    static let idleCaptureCountCap = 60

    static func captureStride(idleCaptureCount: Int) -> Int {
        switch idleCaptureCount {
        case ..<5:
            return 1
        case ..<12:
            return 3
        case ..<30:
            return 6
        default:
            return 10
        }
    }

    var captureStride: Int {
        Self.captureStride(idleCaptureCount: idleCaptureCount)
    }

    mutating func recordCapture(didChange: Bool) {
        idleCaptureCount = didChange ? 0 : min(idleCaptureCount + 1, Self.idleCaptureCountCap)
    }

    mutating func reset() {
        idleCaptureCount = 0
    }
}
