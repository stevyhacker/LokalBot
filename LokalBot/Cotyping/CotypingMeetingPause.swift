import Foundation

enum CotypingMeetingPause {

    static let reason = "Paused while a meeting is recording."

    static func transition(recordingActive: Bool, current: CotypingState) -> CotypingState? {
        if recordingActive {
            return current == .disabled(reason) ? nil : .disabled(reason)
        }
        return current == .disabled(reason) ? .idle : nil
    }
}

enum CotypingLowPowerPause {
    static let reason = "Paused in Low Power Mode."

    static func transition(lowPowerActive: Bool, current: CotypingState) -> CotypingState? {
        if lowPowerActive {
            return current == .disabled(reason) ? nil : .disabled(reason)
        }
        return current == .disabled(reason) ? .idle : nil
    }
}
