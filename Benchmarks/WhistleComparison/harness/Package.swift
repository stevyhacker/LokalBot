// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "WhistleBaselines",
    platforms: [.macOS("15.0")],
    dependencies: [
        .package(url: "https://github.com/stevyhacker/speech-swift", revision: "33f42bc0d48efa5baf39f2531f52c333d92e519a"),
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.17.5"),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.32.3"),
    ],
    targets: [
        .executableTarget(name: "whistle-baselines", dependencies: [
            .product(name: "Qwen3ASR", package: "speech-swift"),
            .product(name: "FluidAudio", package: "FluidAudio"),
            .product(name: "MLX", package: "mlx-swift"),
        ]),
    ]
)
