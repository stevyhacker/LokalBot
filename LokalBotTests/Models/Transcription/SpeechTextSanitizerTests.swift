import XCTest
@testable import LokalBot

final class SpeechTextSanitizerTests: XCTestCase {
    func testPlainTextRemovesMarkdownAndCitations() {
        let markdown = """
        # Summary

        - **Decision:** Ship [LokalBot](https://www.lokalbot.com). [meeting:123@00:01:02]
        - `Next step`: review _Kokoro_ output.
        """

        let text = SpeechTextSanitizer.plainText(fromMarkdown: markdown)

        XCTAssertEqual(text, "Summary Decision: Ship LokalBot. Next step: review Kokoro output.")
    }

    func testPlainTextDropsFencedCode() {
        let markdown = """
        Read this.
        ```
        do not read this aloud
        ```
        Then this.
        """

        let text = SpeechTextSanitizer.plainText(fromMarkdown: markdown)

        XCTAssertEqual(text, "Read this. Then this.")
    }
}

final class SpeechTemporaryOutputCleanupTests: XCTestCase {
    func testCleanupStopsPlaybackBeforeRemovingPlaintextOutput() throws {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("lokalbot-speech-cleanup-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: output) }
        try Data("private summary".utf8).write(to: output)
        var playbackStopped = false

        SpeechTemporaryOutputCleanup.cleanup(output) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
            playbackStopped = true
        }

        XCTAssertTrue(playbackStopped)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
}
