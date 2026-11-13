import XCTest
@testable import LokalBot

final class FileLogSinkTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileLogSinkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testDefaultsKeepAboutFortyMegabytesAcrossFiveRotations() {
        let sink = FileLogSink(fileURL: directory.appendingPathComponent("debug.log"))
        XCTAssertEqual(sink.sizeCapBytes, 8 * 1024 * 1024)
        XCTAssertEqual(sink.maxRotations, 5)
    }

    func testRotationShiftsOlderFilesAndDropsTheOldest() throws {
        let url = directory.appendingPathComponent("debug.log")
        let sink = FileLogSink(fileURL: url, sizeCapBytes: 10, maxRotations: 3)
        for index in 0..<5 {
            sink.write("line-\(index)-0123456789\n")
        }
        let rotated = FileLogSink.rotatedURLs(for: url, maxRotations: 3)
        XCTAssertEqual(rotated.map(\.lastPathComponent), ["debug.log.1", "debug.log.2", "debug.log.3"])
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "line-4-0123456789\n")
        XCTAssertEqual(try String(contentsOf: rotated[0], encoding: .utf8), "line-3-0123456789\n")
        XCTAssertEqual(try String(contentsOf: rotated[2], encoding: .utf8), "line-1-0123456789\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + ".4"))
    }
}
