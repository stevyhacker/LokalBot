import Foundation

struct HardwareCapability: Equatable {
    let physicalMemoryBytes: UInt64
    let isAppleSilicon: Bool
}

enum HardwareCapabilityProbe {
    static func current() -> HardwareCapability {
        HardwareCapability(
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            isAppleSilicon: isAppleSilicon
        )
    }

    private static var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }
}

enum ModelFit: Equatable {
    case comfortable
    case tight
    case tooLarge

    static func evaluate(modelSizeGB: Double, capability: HardwareCapability) -> ModelFit {
        let ramGB = Double(capability.physicalMemoryBytes) / 1_073_741_824.0
        let requiredGB = max(0, modelSizeGB) * 1.3
        if requiredGB <= ramGB * 0.6 {
            return .comfortable
        }
        if requiredGB <= ramGB * 0.8 {
            return .tight
        }
        return .tooLarge
    }

    var advisory: String? {
        switch self {
        case .comfortable:
            return nil
        case .tight:
            return "Uses most of your memory — close other apps for the best speed."
        case .tooLarge:
            return "Likely too large for this Mac's memory; it may run very slowly or fail to load."
        }
    }
}
