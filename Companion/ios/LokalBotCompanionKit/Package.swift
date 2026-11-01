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
            // A link to Companion/protocol/fixtures/sample-library.json, so the
            // sample library and the protocol fixture never drift apart.
            resources: [.copy("Resources/sample-library.json")]),
        .testTarget(
            name: "LokalBotCompanionKitTests",
            dependencies: ["LokalBotCompanionKit"]),
    ]
)
