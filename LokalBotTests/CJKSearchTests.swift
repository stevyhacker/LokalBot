import XCTest
@testable import LokalBot

final class CJKSearchTests: XCTestCase {
    func testDetectsHanKanaAndHangulButNotLatin() {
        XCTAssertTrue(CJKSearch.containsCJK("深色模式"))
        XCTAssertTrue(CJKSearch.containsCJK("こんにちは"))
        XCTAssertTrue(CJKSearch.containsCJK("회의에서"))
        XCTAssertTrue(CJKSearch.containsCJK("用Redis做缓存"))
        XCTAssertFalse(CJKSearch.containsCJK("Café plans for Q3"))
        XCTAssertFalse(CJKSearch.containsCJK("，。？"), "punctuation alone is not CJK text")
    }

    func testTermsSplitOnSpacesAndCJKPunctuationButKeepVersionNumbers() {
        XCTAssertEqual(CJKSearch.terms(from: "深色模式，对比度  2.0.1 e-mail 对比度"),
                       ["深色模式", "对比度", "2.0.1", "e-mail"])
    }

    /// A spaceless question is one long term; relaxed matching ORs its
    /// two-character pieces instead, bounded so a long sentence stays one scan.
    func testRelaxedTermsTurnASpacelessQuestionIntoTwoCharacterPieces() {
        XCTAssertEqual(CJKSearch.relaxedTerms(from: "下周四发布之前，谁还要做什么？"),
                       ["下周", "周四", "四发", "发布", "布之", "之前", "谁还", "还要"])
        XCTAssertEqual(CJKSearch.relaxedTerms(from: "用Redis做缓存"), ["Redis", "做缓", "缓存"],
                       "single CJK characters are too common to match on their own")
        XCTAssertEqual(CJKSearch.relaxedTerms(from: "钉"), ["钉"], "kept when nothing else is left")
        XCTAssertLessThanOrEqual(CJKSearch.relaxedTerms(from: String(repeating: "会议纪要发布", count: 10)).count,
                                 CJKSearch.maximumRelaxedTerms)
    }

    /// Ask's keyword passage strips « », … and requires the rest to be a
    /// contiguous piece of the source, as FTS5's snippet() output is.
    func testSnippetMarksMatchesAndStaysAContiguousPieceOfTheSource() throws {
        let text = "回归测试我们在三台设备上都跑完了，主要流程都没问题，还剩一个小 bug，深色模式下设置页面有几行字对比度太低，看不太清。"
        let snippet = try XCTUnwrap(CJKSearch.snippet(in: text, terms: ["对比度"]))
        XCTAssertTrue(snippet.contains("«对比度»"), snippet)
        let source = snippet.replacingOccurrences(of: "«", with: "").replacingOccurrences(of: "»", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "…"))
        XCTAssertTrue(text.contains(source), snippet)
        XCTAssertNil(CJKSearch.snippet(in: text, terms: ["不存在"]))
        XCTAssertTrue(CJKSearch.snippet(in: "比如LOGO再大一点", terms: ["logo"])?.contains("«LOGO»") == true)
    }

    func testOverlappingPiecesMarkOneSpan() throws {
        let snippet = try XCTUnwrap(CJKSearch.snippet(in: "深色模式下设置页面", terms: ["深色", "色模", "模式"]))
        XCTAssertEqual(snippet, "«深色模式»下设置页面")
    }

    func testLikePatternEscapesWildcards() {
        XCTAssertEqual(CJKSearch.likePattern(for: "50%_off"), #"%50\%\_off%"#)
        XCTAssertEqual(CJKSearch.likePattern(for: #"a\b"#), #"%a\\b%"#)
    }
}
