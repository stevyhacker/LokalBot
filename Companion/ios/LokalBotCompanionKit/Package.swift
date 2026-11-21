// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LokalBotCompanionKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "LokalBotCompanionKit", targets: ["LokalBotCompanionKit"]),
    ],
    targets: [
        .target(
            name: "LokalBotCompanionKit",
            resources: [.copy("Resources/sample-library.json")]),
        .testTarget(
            name: "LokalBotCompanionKitTests",
            dependencies: ["LokalBotCompanionKit"]),
    ]
)
