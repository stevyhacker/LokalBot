// swift-tools-version: 6.0
import PackageDescription

// Everything in the iPhone and iPad app that isn't app shell: record models,
// design tokens and components, the store protocol with its sample-library
// implementation, view models and formatting. macOS is listed so the tests run
// with `swift test` on a Mac.
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
            // A copy of Companion/protocol/fixtures/sample-library.json: some
            // SwiftPM versions bundle a symlink as a dangling link. A test
            // fails when the two differ.
            resources: [.copy("Resources/sample-library.json")]),
        .testTarget(
            name: "LokalBotCompanionKitTests",
            dependencies: ["LokalBotCompanionKit"]),
    ]
)
