import Foundation

nonisolated enum CotypingTextDirectionDetector {
    static func isRightToLeft(_ text: String) -> Bool {
        for scalar in text.unicodeScalars.reversed() {
            if isStrongRTL(scalar) { return true }
            if isStrongLTR(scalar) { return false }
        }
        return false
    }

    private static func isStrongRTL(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value >= 0x0590 && value <= 0x08FF { return true }
        if value >= 0xFB1D && value <= 0xFDFF { return true }
        if value >= 0xFE70 && value <= 0xFEFF { return true }
        if value == 0x200F || value == 0x061C { return true }
        return false
    }

    private static func isStrongLTR(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value >= 0x0041 && value <= 0x005A { return true }
        if value >= 0x0061 && value <= 0x007A { return true }
        if value >= 0x00C0 && value <= 0x024F { return true }
        if value >= 0x0370 && value <= 0x03FF { return true }
        if value >= 0x0400 && value <= 0x04FF { return true }
        if value >= 0x4E00 && value <= 0x9FFF { return true }
        if value == 0x200E { return true }
        return false
    }
}
