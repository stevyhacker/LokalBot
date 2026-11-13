import XCTest
@testable import LokalBot

/// Escaped-bug regression for #368. These tests need no models or audio.
final class UkrainianLanguageSelectionTests: XCTestCase {
    func testUkrainianIsSelectableWithAnExplicitEngineCode() throws {
        let language = try XCTUnwrap(TranscriptionLanguage(rawValue: "uk"))
        XCTAssertEqual(language.code, "uk")
        XCTAssertEqual(language.displayName, "Ukrainian")
        XCTAssertEqual(TranscriptionLanguage.allCases.filter { $0.rawValue == "uk" }, [language])
    }

    func testUkrainianDecodesAndRoundTripsWithoutFallingBackToAuto() throws {
        let language = try JSONDecoder().decode(TranscriptionLanguage.self, from: Data(#""uk""#.utf8))
        XCTAssertEqual(language.code, "uk")
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(language), as: UTF8.self), #""uk""#)
    }

    func testLegacyUkrainianHintMigratesWithoutBecomingAutoDetect() {
        XCTAssertEqual(TranscriptionLanguage.fromLegacyHint(" UK \n").code, "uk")
    }

    func testUnknownLanguageStillFailsDecoding() {
        XCTAssertThrowsError(try JSONDecoder().decode(TranscriptionLanguage.self, from: Data(#""unknown""#.utf8)))
        XCTAssertNil(TranscriptionLanguage(rawValue: "unknown"))
    }

    func testAutoDetectStillHasNoEngineHint() throws {
        let language = try JSONDecoder().decode(TranscriptionLanguage.self, from: Data(#""auto""#.utf8))
        XCTAssertNil(language.code)
        XCTAssertEqual(language, .auto)
    }
}
