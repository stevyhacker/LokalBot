// swift-tools-version: 5.10
// Headless span-length harness for LokalBot's Qwen3-ASR engine path.
// Pins match LokalBot's project.yml / Package.resolved exactly.
import PackageDescription

let package = Package(
    name: "QwenSpanHarness",
    platforms: [.macOS("15.0")],
    dependencies: [
        .package(url: "https://github.com/soniqo/speech-swift", exact: "0.0.26"),
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.17.1"),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.4"),
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
