// swift-tools-version: 5.10
// Headless span-length harness for LokalBot's Qwen3-ASR engine path.
// Pins match LokalBot's project.yml / Package.resolved exactly (2026-11-15):
// the speech-swift fork at 8e87821 (v0.0.29), FluidAudio 0.18.3 and mlx-swift 0.32.3.
// The 2026-09-30 results used speech-swift 0.0.26, FluidAudio 0.17.1 and mlx-swift 0.31.4.
import PackageDescription

let package = Package(
    name: "QwenSpanHarness",
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
