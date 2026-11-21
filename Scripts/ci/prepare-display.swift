import CoreGraphics
import Foundation

func prepareDisplay() throws {
    guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else {
        throw NSError(domain: "HostedDisplay", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Display preparation is restricted to GitHub Actions."])
    }
    let display = CGMainDisplayID()
    func hasRoom() -> Bool {
        let bounds = CGDisplayBounds(display)
        return bounds.width >= 1600 && bounds.height >= 1000
    }
    func waitForRoom() -> Bool {
        for _ in 0..<80 {
            if hasRoom() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return hasRoom()
    }
    print("Hosted display before preparation: \(CGDisplayBounds(display))")
    if hasRoom() { return }
    if CommandLine.arguments.contains("--verify-only") {
        throw NSError(domain: "HostedDisplay", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "The desktop reverted after display preparation exited."])
    }
    let modes = CGDisplayCopyAllDisplayModes(display, nil) as? [CGDisplayMode] ?? []
    let suitable = modes.filter { $0.width >= 1600 && $0.height >= 1000 }
        .sorted { $0.width * $0.height < $1.width * $1.height }
    for mode in suitable {
        var configuration: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configuration) == .success,
              let configuration else { continue }
        guard CGConfigureDisplayWithDisplayMode(configuration, display, mode, nil) == .success else {
            CGCancelDisplayConfiguration(configuration)
            continue
        }
        let result = CGCompleteDisplayConfiguration(configuration, .forSession)
        print("Requested \(mode.width)×\(mode.height): \(result.rawValue)")
        if result == .success, waitForRoom() { return }
    }
    for path in [
        "/Library/Application Support/Veertu/Anka/addons/change_res",
        "/Library/Application Support/Veertu/Anka/guestaddons/change_res",
    ] where FileManager.default.isExecutableFile(atPath: path) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["1600x1000x32@30"]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus == 0, waitForRoom() { return }
    }
    let available = modes.map { "\($0.width)×\($0.height)" }.joined(separator: ", ")
    throw NSError(domain: "HostedDisplay", code: 2, userInfo: [
        NSLocalizedDescriptionKey: "Cannot provide a 1600×1000 desktop. Available modes: \(available)"])
}

do {
    try prepareDisplay()
    print("Hosted display ready: \(CGDisplayBounds(CGMainDisplayID()))")
} catch {
    fputs("Hosted display preparation failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
