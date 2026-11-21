import Foundation

enum DiskSpacePrecheck {

    static let headroomBytes: Int64 = 2_000_000_000

    static func advisory(expectedBytes: Int64?, availableBytes: Int64?) -> String? {
        guard let expectedBytes, expectedBytes > 0, let availableBytes else { return nil }
        guard availableBytes < expectedBytes + headroomBytes else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let needed = formatter.string(fromByteCount: expectedBytes + headroomBytes)
        let free = formatter.string(fromByteCount: max(0, availableBytes))
        return "Not enough free disk space: this model needs about \(needed) free "
            + "(download plus headroom), but only \(free) is available. "
            + "Free up space or pick a smaller model."
    }

    static let recordingFloorBytes: Int64 = 1_000_000_000

    static func recordingAdvisory(availableBytes: Int64?) -> String? {
        guard let availableBytes, availableBytes < recordingFloorBytes else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let floor = formatter.string(fromByteCount: recordingFloorBytes)
        let free = formatter.string(fromByteCount: max(0, availableBytes))
        return "Recording needs at least \(floor) of free disk space, "
            + "but only \(free) is available. Free up space and try again."
    }

    static func availableBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
