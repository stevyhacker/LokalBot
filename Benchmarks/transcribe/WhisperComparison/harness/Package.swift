// swift-tools-version: 5.10
import Foundation
import PackageDescription

let whisper: Package.Dependency = ProcessInfo.processInfo.environment["WHISPERKIT_SOURCE"].map {
    .package(path: $0)
} ?? .package(url: "https://github.com/argmaxinc/WhisperKit", exact: "1.1.0")

let package = Package(
    name: "WhisperComparison",
    platforms: [.macOS("15.0")],
    dependencies: [whisper],
    targets: [.executableTarget(name: "whisper-comparison", dependencies: [
        .product(name: "WhisperKit", package: "WhisperKit")
    ])]
)
