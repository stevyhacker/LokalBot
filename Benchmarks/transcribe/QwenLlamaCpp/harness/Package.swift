// swift-tools-version: 5.10
// The QwenSpanLength harness (symlinked sources) built against the app's current
// pins from LokalBot.xcodeproj's Package.resolved (2026-11-14): the speech-swift
// fork at 33f42bc, FluidAudio 0.17.7 and mlx-swift 0.32.3.
import PackageDescription

let package = Package(
    name: "QwenBackendHarness",
    platforms: [.macOS("15.0")],
    dependencies: [
        .package(url: "https://github.com/stevyhacker/speech-swift", revision: "33f42bc0d48efa5baf39f2531f52c333d92e519a"),
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.17.7"),
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
