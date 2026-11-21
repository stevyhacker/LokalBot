import AppKit
import CoreGraphics

struct EventTapAudit: Encodable, Equatable {
    struct Tap: Equatable, Sendable {
        var processID: pid_t
        var enabled: Bool
    }

    struct Holder: Encodable, Equatable {
        var processID: Int32
        var name: String
        var bundleID: String?
        var taps: Int
        var enabled: Int
        var isLokalBot: Bool
        var likelyLeaking: Bool
    }

    static let lokalBotMaximum = 3
    static let likelyLeakThreshold = 5

    var holders: [Holder]
    var lokalBotTaps: Int
    var lokalBotWithinMaximum: Bool

    init(taps: [Tap], lokalBotBundleID: String?, describe: (pid_t) -> (name: String, bundleID: String?)) {
        var byProcess: [pid_t: [Tap]] = [:]
        for tap in taps { byProcess[tap.processID, default: []].append(tap) }
        var holders: [Holder] = []
        for (processID, held) in byProcess {
            let description = describe(processID)
            let isLokalBot = lokalBotBundleID != nil && description.bundleID == lokalBotBundleID
            holders.append(Holder(
                processID: processID,
                name: description.name,
                bundleID: description.bundleID,
                taps: held.count,
                enabled: held.filter(\.enabled).count,
                isLokalBot: isLokalBot,
                likelyLeaking: held.count >= Self.likelyLeakThreshold))
        }
        holders.sort { lhs, rhs in
            if lhs.taps != rhs.taps { return lhs.taps > rhs.taps }
            return lhs.name < rhs.name
        }
        self.holders = holders
        var lokalBotTaps = 0
        for holder in holders where holder.isLokalBot { lokalBotTaps += holder.taps }
        self.lokalBotTaps = lokalBotTaps
        lokalBotWithinMaximum = lokalBotTaps <= Self.lokalBotMaximum
    }

    static func installedTaps() -> [Tap] {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else { return [] }
        var list = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        guard CGGetEventTapList(count, &list, &count) == .success else { return [] }
        return list.prefix(Int(count)).map { Tap(processID: $0.tappingProcess, enabled: $0.enabled) }
    }

    static func printCurrent() -> Int32 {
        let audit = EventTapAudit(
            taps: installedTaps(),
            lokalBotBundleID: Bundle.main.bundleIdentifier) { processID in
                let app = NSRunningApplication(processIdentifier: processID)
                return (app?.localizedName ?? "pid \(processID)", app?.bundleIdentifier)
            }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(audit) else { return 1 }
        FileHandle.standardOutput.write(data + Data([10]))
        return 0
    }
}
