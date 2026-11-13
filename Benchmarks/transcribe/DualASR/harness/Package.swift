// swift-tools-version: 5.10
// Headless Qwen3-ASR / Whisper comparison harness on LokalBot's decode windows.
// Pins match LokalBot's project.yml / Package.resolved exactly.
import PackageDescription

let package = Package(
    name: "DualASRHarness",
    platforms: [.macOS("15.0")],
    dependencies: [
        .package(url: "https://github.com/soniqo/speech-swift", exact: "0.0.28"),
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.17.5"),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.4"),
        .package(url: "https://github.com/argmaxinc/WhisperKit", exact: "1.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "dual-asr-harness",
            dependencies: [
                .product(name: "Qwen3ASR", package: "speech-swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "WhisperKit", package: "WhisperKit"),
            ]
        ),
    ]
)
