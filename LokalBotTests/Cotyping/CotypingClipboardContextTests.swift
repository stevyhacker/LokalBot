import AppKit
import XCTest
@testable import LokalBot

// MARK: - Clipboard context

final class CotypingClipboardContextTests: XCTestCase {
    func testSanitizeCollapsesAndTrims() {
        XCTAssertEqual(CotypingClipboardContext.sanitize("  hello   world  "), "hello world")
        XCTAssertEqual(CotypingClipboardContext.sanitize("a\n\nb\tc"), "a\nb c")
        XCTAssertEqual(CotypingClipboardContext.sanitize("hello"), "hello")
    }

    func testSanitizeStripsAnsiEscapesAndPromptShapedPunctuation() {
        let input = "\u{001B}[31mraw-output\u{001B}[0m ```$ deploy --prod```"

        XCTAssertEqual(CotypingClipboardContext.sanitize(input), "raw output deploy prod")
    }

    func testSanitizeDropsEmpty() {
        XCTAssertNil(CotypingClipboardContext.sanitize(nil))
        XCTAssertNil(CotypingClipboardContext.sanitize(""))
        XCTAssertNil(CotypingClipboardContext.sanitize("   \n\t  "))
        XCTAssertNil(CotypingClipboardContext.sanitize("*** --- ```"))
    }

    func testSanitizeCapsLength() {
        let long = String(repeating: "x", count: 2000)
        let capped = CotypingClipboardContext.sanitize(long)
        XCTAssertEqual(capped?.count, CotypingClipboardContext.maxSnippetCharacters)
    }

    func testShouldIncludeGuardsAlreadyInField() {
        XCTAssertFalse(CotypingClipboardContext.shouldInclude(snippet: "abc", precedingText: "x abc y"))
        XCTAssertTrue(CotypingClipboardContext.shouldInclude(snippet: "abc", precedingText: "hello"))
        XCTAssertTrue(CotypingClipboardContext.shouldInclude(snippet: "abc", precedingText: ""))
        XCTAssertFalse(CotypingClipboardContext.shouldInclude(snippet: nil, precedingText: "hi"))
        XCTAssertFalse(CotypingClipboardContext.shouldInclude(snippet: "", precedingText: "hi"))
        XCTAssertFalse(CotypingClipboardContext.shouldInclude(
            snippet: "raw output",
            precedingText: "The raw-output log is attached"))
    }

    func testResolveCombinesSanitizeAndGuard() {
        XCTAssertEqual(CotypingClipboardContext.resolve(rawClipboard: "plans", precedingText: "meeting about"), "plans")
        XCTAssertNil(CotypingClipboardContext.resolve(rawClipboard: "plans", precedingText: "the plans are set"))  // already there
        XCTAssertNil(CotypingClipboardContext.resolve(rawClipboard: "   ", precedingText: "x"))                    // empty after sanitize
    }

    func testResolveDistillsLongClipboardToLinesOverlappingThePrefix() {
        let raw = """
        invoice totals and renewal schedule
        unrelated terminal output
        api rollout notes
        renewal customer summary
        """

        let result = CotypingClipboardContext.resolve(
            rawClipboard: raw,
            precedingText: "I will send the renewal update")

        XCTAssertEqual(result, "invoice totals and renewal schedule\nrenewal customer summary")
    }

    func testPromptIncludesClipboardLine() {
        let prompt = CotypingPromptRenderer.prompt(prefixText: "hello", clipboardContext: "secret plans")
        XCTAssertTrue(prompt.contains("On the clipboard: secret plans"))
        XCTAssertTrue(prompt.contains("hello"))  // prefix still present
    }

    func testPromptOmitsClipboardWhenAbsent() {
        let prompt = CotypingPromptRenderer.prompt(prefixText: "hello")
        XCTAssertFalse(prompt.contains("On the clipboard"))
    }

    func testPromptCapsClipboardLine() {
        let huge = String(repeating: "z", count: 600)
        let prompt = CotypingPromptRenderer.prompt(prefixText: "hi", clipboardContext: huge)
        // The clipboard line itself is capped at maxClipboardLineCharacters.
        let line = prompt.components(separatedBy: "\n").first(where: { $0.contains("On the clipboard") }) ?? ""
        XCTAssertLessThanOrEqual(line.count, "On the clipboard: ".count + CotypingPromptRenderer.maxClipboardLineCharacters)
    }

    func testUseClipboardDefaultsOnAndExplicitOptOutRoundTrips() throws {
        XCTAssertTrue(AppSettings().cotypingUseClipboard)

        var settings = AppSettings()
        settings.cotypingUseClipboard = false
        let decoded = try JSONDecoder().decode(
            AppSettings.self, from: JSONEncoder().encode(settings))

        XCTAssertFalse(decoded.cotypingUseClipboard)
    }

    func testClipboardSignificantTokensIgnoreShortTokensAndCase() {
        XCTAssertEqual(
            CotypingClipboardContext.significantTokens(from: "A deployment, API, and x y z"),
            ["deployment", "api", "and"])
    }

    func testClipboardRelevanceFirstObservationBaselinesWithoutInjecting() {
        let filter = CotypingClipboardRelevanceFilter()

        XCTAssertNil(filter.filter(
            rawClipboard: "meeting agenda",
            pasteboardChangeCount: 42,
            precedingText: "the meeting starts soon"))
    }

    func testClipboardRelevanceFreshCopyRequiresTokenOverlap() {
        let filter = CotypingClipboardRelevanceFilter()
        _ = filter.filter(
            rawClipboard: "baseline content",
            pasteboardChangeCount: 1,
            precedingText: "")

        XCTAssertNil(filter.filter(
            rawClipboard: "SELECT * FROM users",
            pasteboardChangeCount: 2,
            precedingText: "Dear hiring manager"))
        XCTAssertEqual(filter.filter(
            rawClipboard: "Deployment Pipeline",
            pasteboardChangeCount: 3,
            precedingText: "the deployment is running"),
            "Deployment Pipeline")
    }

    func testClipboardRelevanceIgnoresShortTokenOverlap() {
        let filter = CotypingClipboardRelevanceFilter()
        _ = filter.filter(
            rawClipboard: "baseline content",
            pasteboardChangeCount: 1,
            precedingText: "")

        XCTAssertNil(filter.filter(
            rawClipboard: "a b c",
            pasteboardChangeCount: 2,
            precedingText: "a b c d e"))
    }

    func testClipboardRelevanceExpiresAndNewCopyResetsClock() {
        var now = Date()
        let filter = CotypingClipboardRelevanceFilter(dateProvider: { now })
        _ = filter.filter(
            rawClipboard: "baseline content",
            pasteboardChangeCount: 1,
            precedingText: "")

        XCTAssertEqual(filter.filter(
            rawClipboard: "first content",
            pasteboardChangeCount: 2,
            precedingText: "first content"),
            "first content")

        now = now.addingTimeInterval(CotypingClipboardRelevanceFilter.staleThresholdSeconds + 1)

        XCTAssertNil(filter.filter(
            rawClipboard: "first content",
            pasteboardChangeCount: 2,
            precedingText: "first content"))
        XCTAssertEqual(filter.filter(
            rawClipboard: "second content",
            pasteboardChangeCount: 3,
            precedingText: "second content"),
            "second content")
    }

    func testClipboardPrefaceMemoReusesOnlySameFieldAndChangeCount() {
        let memo = CotypingClipboardPrefaceMemo(
            identityKey: "field-a",
            changeCount: 12,
            value: "release notes")

        XCTAssertEqual(
            memo.valueIfReusable(identityKey: "field-a", changeCount: 12),
            "release notes")
        XCTAssertNil(memo.valueIfReusable(identityKey: "field-b", changeCount: 12))
        XCTAssertNil(memo.valueIfReusable(identityKey: "field-a", changeCount: 13))
    }

    func testClipboardPrefaceResolverUsesPinnedMemoBeforeRelevanceFilter() {
        let filter = CotypingClipboardRelevanceFilter()
        _ = filter.filter(
            rawClipboard: "baseline content",
            pasteboardChangeCount: 1,
            precedingText: "")
        let memo = CotypingClipboardPrefaceMemo(
            identityKey: "field-a",
            changeCount: 2,
            value: "Deployment Pipeline")

        let resolution = CotypingClipboardPrefaceResolver.resolve(
            rawClipboard: "Deployment Pipeline",
            pasteboardChangeCount: 2,
            precedingText: "Dear hiring manager",
            identityKey: "field-a",
            memo: memo,
            relevanceFilter: filter)

        XCTAssertEqual(resolution.value, "Deployment Pipeline")
        XCTAssertEqual(resolution.memo, memo)
    }
}

@MainActor
final class CotypingClipboardProviderTests: XCTestCase {
    func testSensitiveMarkersPreventAnyTextRead() {
        for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "com.agilebits.onepassword"] {
            var reads = 0
            let provider = CotypingClipboardProvider(changeCount: { 1 },
                types: { [.string, NSPasteboard.PasteboardType(marker)] }, text: { reads += 1; return "secret" })
            XCTAssertNil(provider.snapshot())
            XCTAssertEqual(reads, 0)
        }
    }

    func testPasteboardChangeDuringTextReadRejectsSnapshot() {
        var count = 1
        let provider = CotypingClipboardProvider(changeCount: { count }, types: { [.string] }, text: {
            count += 1
            return "changed"
        })
        XCTAssertNil(provider.snapshot())
    }

    func testMarkerAppearingDuringTextReadRejectsSnapshot() {
        var types: [NSPasteboard.PasteboardType] = [.string]
        let provider = CotypingClipboardProvider(changeCount: { 1 }, types: { types }, text: {
            types.append(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
            return "changed"
        })
        XCTAssertNil(provider.snapshot())
    }

    func testUnavailableSnapshotClearsPreviouslyPinnedContext() {
        let filter = CotypingClipboardRelevanceFilter()
        let old = CotypingClipboardPrefaceMemo(identityKey: "field", changeCount: 1, value: "old private memo")
        let result = CotypingClipboardPrefaceResolver.resolve(snapshot: nil, precedingText: "private memo", identityKey: "field",
                                                             memo: old, relevanceFilter: filter)
        XCTAssertNil(result.value)
        XCTAssertNil(result.memo)
        let ordinary = CotypingClipboardProvider(changeCount: { 2 }, types: { [.string] }, text: { "private memo" })
        let fresh = CotypingClipboardPrefaceResolver.resolve(snapshot: ordinary.snapshot(), precedingText: "private memo",
                                                            identityKey: "field", memo: result.memo, relevanceFilter: filter)
        XCTAssertNil(fresh.value, "the first observation after sensitive content must establish a new baseline")
    }
}
