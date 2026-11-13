import XCTest
@testable import LokalBot

final class HelperVersionTests: XCTestCase {
    func testReadsVersionFromEnclosingAppBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("helperversion-\(UUID().uuidString)")
        let helpers = root.appendingPathComponent("Fake.app/Contents/Helpers")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleShortVersionString": "9.9.9"],
            format: .xml,
            options: 0)
        try plist.write(to: root.appendingPathComponent("Fake.app/Contents/Info.plist"))
        let binary = helpers.appendingPathComponent("lokalbot-cli")
        try Data().write(to: binary)

        XCTAssertEqual(HelperVersion.current(binaryPath: binary.path), "9.9.9")
    }

    func testFallsBackToDevOutsideABundle() {
        XCTAssertEqual(HelperVersion.current(binaryPath: "/tmp/loose-binary"), "dev")
    }

    /// `lokalbot-cli --version` answers from the app bundle alone. It runs
    /// through a PATH symlink like `~/.local/bin/lokalbot-cli`, where argv[0]
    /// is only the bare name, against a library root that must stay untouched.
    func testEmbeddedHelperPrintsVersionThroughPATHSymlink() throws {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/lokalbot-cli")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw XCTSkip("no embedded lokalbot-cli in this build")
        }
        let version = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("helperversion-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin")
        let library = root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(
            at: bin.appendingPathComponent("lokalbot-cli"),
            withDestinationURL: helper)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["lokalbot-cli", "--version"]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = bin.path
        environment["LOKALBOT_STORAGE_ROOT"] = library.path
        process.environment = environment
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "lokalbot-cli \(version)\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path))
    }
}
