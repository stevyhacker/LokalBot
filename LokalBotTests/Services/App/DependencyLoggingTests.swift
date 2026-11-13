import Darwin
import FluidAudio
import XCTest
@testable import LokalBot

final class DependencyLoggingTests: XCTestCase {
    func testStartupKeepsRecognizedWordsOffDebugConsole() throws {
        let previousLevel = AppLogger.minimumLevel
        let previousConsole = AppLogger.mirrorsToConsole
        defer {
            AppLogger.minimumLevel = previousLevel
            AppLogger.mirrorsToConsole = previousConsole
        }
        AppLogger.minimumLevel = .debug
        AppLogger.mirrorsToConsole = true
        LokalBotMain.configureDependencyLogging()
        XCTAssertEqual(AppLogger.minimumLevel, .warning)
        XCTAssertFalse(AppLogger.mirrorsToConsole)

        let pipe = Pipe()
        let original = dup(STDERR_FILENO)
        XCTAssertGreaterThanOrEqual(original, 0)
        defer { close(original) }
        XCTAssertGreaterThanOrEqual(dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO), 0)
        let logger = AppLogger(category: "dependency-privacy-regression")
        logger.debug("synthetic-private-transcript-debug")
        logger.info("synthetic-private-transcript-info")
        logger.notice("synthetic-private-transcript-notice")
        XCTAssertGreaterThanOrEqual(dup2(original, STDERR_FILENO), 0)
        try pipe.fileHandleForWriting.close()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        XCTAssertTrue(output.isEmpty, "Transcription payloads must never reach dependency stderr logging")
    }
}
