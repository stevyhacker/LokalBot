import CoreGraphics
import Foundation

// Gives the hosted desktop a Retina (2x) mode when the runner offers one, so
// the filmed text stays sharp when the cut scales it up. Lists every mode it
// sees; falls back to the widest 1x mode. Either has room for the takes'
// windows, which are 1760 points wide.
//
//   swift Scripts/autocomplete-demo/display.swift
guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else {
    FileHandle.standardError.write(Data("display: only changes the hosted desktop in GitHub Actions\n".utf8))
    exit(1)
}
let display = CGMainDisplayID()
let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
let modes = CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode] ?? []
func describe(_ mode: CGDisplayMode) -> String {
    "\(mode.width)×\(mode.height) pt, \(mode.pixelWidth)×\(mode.pixelHeight) px @\(Int(mode.refreshRate))Hz"
}
print("Display before: \(CGDisplayBounds(display)), \(CGDisplayCopyDisplayMode(display).map(describe) ?? "?")")
for mode in modes { print("  mode \(describe(mode))") }

let retina = modes.filter { $0.pixelWidth == 2 * $0.width && $0.width >= 1792 && $0.height >= 900 }
    .sorted { $0.width * $0.height > $1.width * $1.height }
let wide = modes.filter { $0.width >= 1792 && $0.height >= 900 }
    .sorted { ($0.width, $0.height) > ($1.width, $1.height) }
for mode in retina + wide {
    var configuration: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&configuration) == .success, let configuration else { continue }
    guard CGConfigureDisplayWithDisplayMode(configuration, display, mode, nil) == .success else {
        CGCancelDisplayConfiguration(configuration)
        continue
    }
    let result = CGCompleteDisplayConfiguration(configuration, .forSession)
    Thread.sleep(forTimeInterval: 1.5)
    let now = CGDisplayCopyDisplayMode(display)
    print("Requested \(describe(mode)): \(result.rawValue); now \(now.map(describe) ?? "?")")
    if result == .success, let now, now.width == mode.width, now.pixelWidth == mode.pixelWidth { break }
}
print("Display after: \(CGDisplayBounds(display)), \(CGDisplayCopyDisplayMode(display).map(describe) ?? "?")")
