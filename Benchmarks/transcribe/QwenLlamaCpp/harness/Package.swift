// swift-tools-version: 5.10
// The QwenSpanLength harness (symlinked sources) built against the app's current
// pins from LokalBot.xcodeproj's Package.resolved (after PR 500, 2026-11-14): the
// speech-swift fork at 8e87821 (v0.0.29), FluidAudio 0.18.3 and mlx-swift 0.32.3.
import PackageDescription

let package = Package(
    name: "QwenBackendHarness",
    platforms: [.macOS("15.0")],
    dependencies: [
        .package(url: "https://github.com/stevyhacker/speech-swift", revision: "8e8782120803e8812805041b9ae51197c5959c31"),
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.18.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.32.3"),
    ],
    targets: [
        .executableTarget(
            name: "qwen-span-harness",
            dependencies: [
                .product(name: "Qwen3ASR", package: "speech-swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "MLX", package: "mlx-swift"),
            ]
        ),
    ]
)
