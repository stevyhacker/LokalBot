import AppKit
import XCTest
@testable import LokalBot

// MARK: - Suggestion anchor cache

final class CotypingSuggestionAnchorCacheTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_000_000)
    private let requestFingerprint = "request-a"

    private func makeCache() -> CotypingSuggestionAnchorCache {
        CotypingSuggestionAnchorCache(now: { self.clock })
    }

    func testFreshAnchorMatchesAtZeroConsumed() {
        var cache = makeCache()
        cache.record(identityKey: "field", requestFingerprint: requestFingerprint, precedingText: "Hello", fullText: " world again")
        XCTAssertEqual(cache.remainder(identityKey: "field", requestFingerprint: requestFingerprint, precedingText: "Hello"), " world again")
    }

    func testTypeThroughConsumesPrefix() {
        var cache = makeCache()
        cache.record(identityKey: "field", requestFingerprint: requestFingerprint, precedingText: "Hello", fullText: " world again")
        XCTAssertEqual(cache.remainder(identityKey: "field", requestFingerprint: requestFingerprint, precedingText: "Hello wo"), "rld again")
    }

    func testBackspaceRollbackRestoresEarlierPosition() {
        var cache = makeCache()
        cache.record(identityKey: "field", requestFingerprint: requestFingerprint, precedingText: "Hello", fullText: " world again")
        XCTAssertEqual(cache.remainder(identityKey: "field", requestFingerprint: requestFingerprint, precedingText: "Hello wo"), "rld again")
        XCTAssertEqual(cache.remainder(identityKey: "field", requestFingerprint: requestFingerprint, precedingText: "Hello"), " world again")
    }

    func testFullyConsumedSuggestionNeverReoffersItsTail() {
        var cache = makeCache()
        cache.record(identityKey: "field", requestFingerprint: requestFingerprint, precedingText: "Hello", fullText: " world")
        XCTAssertNil(cache.remainder(identityKey: "field", requestFingerprint: requestFingerprint, precedingText: "Hello world"))
    }

    func testDivergentTypingDoesNotMatch() {
        var cache = makeCache()
        cache.record(identityKey: "field", requestFingerprint: requestFingerprint, precedingText: "Hello", fullText: " world again")
        XCTAssertNil(cache.remainder(identityKey: "field", requestFingerprint: requestFingerprint, precedingText: "Hello wa"))
    }

    func testDifferentFieldDoesNotMatch() {
        var cache = makeCache()
        cache.record(identityKey: "first", requestFingerprint: requestFingerprint, precedingText: "Hello", fullText: " world")
        XCTAssertNil(cache.remainder(identityKey: "second", requestFingerprint: requestFingerprint, precedingText: "Hello"))
    }

    func testDifferentRequestFingerprintDoesNotMatch() {
        var cache = makeCache()
        cache.record(identityKey: "field", requestFingerprint: "request-a", precedingText: "Hello", fullText: " world")
        XCTAssertNil(cache.remainder(identityKey: "field", requestFingerprint: "request-b", precedingText: "Hello"))
    }

    func testDeepestConsumedMatchWins() {
        var cache = makeCache()
        cache.record(identityKey: "field", requestFingerprint: requestFingerprint, precedingText: "Hello", fullText: " world again")
        cache.record(identityKey: "field", requestFingerprint: requestFingerprint, precedingText: "Hello wo", fullText: "rld forever")
        XCTAssertEqual(cache.remainder(identityKey: "field", requestFingerprint: requestFingerprint, precedingText: "Hello wor"), "ld again")
    }

    func testEntriesExpire() {
        var cache = makeCache()
        cache.record(identityKey: "field", requestFingerprint: requestFingerprint, precedingText: "Hello", fullText: " world")
        clock = clock.addingTimeInterval(CotypingSuggestionAnchorCache.maxEntryAge + 1)
        XCTAssertNil(cache.remainder(identityKey: "field", requestFingerprint: requestFingerprint, precedingText: "Hello"))
    }

    func testCapacityEvictsOldest() {
        var cache = makeCache()
        for index in 0..<(CotypingSuggestionAnchorCache.capacity + 4) {
            cache.record(identityKey: "field", requestFingerprint: requestFingerprint, precedingText: "prefix \(index)", fullText: "suffix \(index)")
        }
        XCTAssertNil(cache.remainder(identityKey: "field", requestFingerprint: requestFingerprint, precedingText: "prefix 0"))
        XCTAssertEqual(
            cache.remainder(
                identityKey: "field",
                requestFingerprint: requestFingerprint,
                precedingText: "prefix \(CotypingSuggestionAnchorCache.capacity + 3)"),
            "suffix \(CotypingSuggestionAnchorCache.capacity + 3)")
    }

    func testLongPrefixesMatchOnTheBoundedTail() {
        var cache = makeCache()
        let longPrefix = String(repeating: "a", count: 2_000) + " ending here"
        cache.record(identityKey: "field", requestFingerprint: requestFingerprint, precedingText: longPrefix, fullText: " and more")
        XCTAssertEqual(cache.remainder(identityKey: "field", requestFingerprint: requestFingerprint, precedingText: longPrefix + " and"), " more")
    }

    func testRemoveAllEmptiesTheCache() {
        var cache = makeCache()
        cache.record(identityKey: "field", requestFingerprint: requestFingerprint, precedingText: "Hello", fullText: " world")
        cache.removeAll()
        XCTAssertNil(cache.remainder(identityKey: "field", requestFingerprint: requestFingerprint, precedingText: "Hello"))
    }

    /// A tail shown again from the cache can still be topped up when the
    /// suggestion it came from could.
    func testARestoredTailKeepsWhetherItMayBeToppedUp() throws {
        var cache = makeCache()
        cache.record(identityKey: "field", requestFingerprint: requestFingerprint, precedingText: "Hello",
                     fullText: " world again and", isOpenEnded: true)
        cache.record(identityKey: "other", requestFingerprint: requestFingerprint, precedingText: "Hello",
                     fullText: " there.")
        let open = try XCTUnwrap(cache.restoration(
            identityKey: "field", requestFingerprint: requestFingerprint, precedingText: "Hello wo"))
        XCTAssertEqual(open, .init(text: "rld again and", isOpenEnded: true))
        let closed = try XCTUnwrap(cache.restoration(
            identityKey: "other", requestFingerprint: requestFingerprint, precedingText: "Hello"))
        XCTAssertEqual(closed, .init(text: " there.", isOpenEnded: false))
    }
}

final class CotypingSuggestionCacheFingerprintTests: XCTestCase {
    private func request(
        prefix: String = "Hello",
        trailing: String = "",
        conditioningPreface: String? = "Written by Ada.",
        generation: UInt64 = 1
    ) -> CotypingRequest {
        CotypingRequest(
            prompt: [conditioningPreface, prefix].compactMap { $0 }.joined(separator: "\n"),
            prefixText: prefix,
            trailingText: trailing,
            isMultiLine: false,
            maxTokens: 5,
            maxWords: 3,
            temperature: 0.1,
            topP: 0.7,
            topK: 20,
            minP: 0.08,
            repeatPenalty: 1.05,
            seed: 0x00C0_FFEE,
            generation: generation,
            conditioningPreface: conditioningPreface)
    }

    func testHybridSwitchCannotReuseSuggestionsFromTheOtherDecoder() {
        var settings = AppSettings()
        let current = CotypingSuggestionCacheFingerprint.make(request: request(), settings: settings)
        settings.cotypingSelectiveOneWordHybrid = true
        let hybrid = CotypingSuggestionCacheFingerprint.make(request: request(), settings: settings)
        XCTAssertNotEqual(current, hybrid)
        var cache = CotypingSuggestionAnchorCache()
        cache.record(identityKey: "field", requestFingerprint: hybrid, precedingText: "Hello", fullText: " world")
        XCTAssertNil(cache.remainder(identityKey: "field", requestFingerprint: current, precedingText: "Hello"))
        settings.cotypingSelectiveOneWordHybrid = false
        XCTAssertEqual(current, CotypingSuggestionCacheFingerprint.make(request: request(), settings: settings))
    }

    func testFingerprintChangesWithOutputAffectingSettingsAndRequestContext() {
        var settings = AppSettings()
        let baselineRequest = request()
        let baseline = CotypingSuggestionCacheFingerprint.make(
            request: baselineRequest,
            settings: settings)

        settings.cotypingBuiltInModelID = ModelCatalog.compactFallbackID
        XCTAssertNotEqual(
            baseline,
            CotypingSuggestionCacheFingerprint.make(request: baselineRequest, settings: settings))

        settings = AppSettings()
        settings.cotypingInProcessRuntime.toggle()
        XCTAssertNotEqual(
            baseline,
            CotypingSuggestionCacheFingerprint.make(request: baselineRequest, settings: settings))

        settings = AppSettings()
        settings.cotypingUserName = "Grace"
        XCTAssertNotEqual(
            baseline,
            CotypingSuggestionCacheFingerprint.make(request: baselineRequest, settings: settings))

        settings = AppSettings()
        settings.cotypingUseClipboard.toggle()
        XCTAssertNotEqual(
            baseline,
            CotypingSuggestionCacheFingerprint.make(request: baselineRequest, settings: settings))

        settings = AppSettings()
        settings.cotypingLearningExamplesInPrompt += 1
        XCTAssertNotEqual(
            baseline,
            CotypingSuggestionCacheFingerprint.make(request: baselineRequest, settings: settings))

        XCTAssertNotEqual(
            baseline,
            CotypingSuggestionCacheFingerprint.make(
                request: request(conditioningPreface: "Learned example: ship it."),
                settings: AppSettings()))
        XCTAssertNotEqual(
            baseline,
            CotypingSuggestionCacheFingerprint.make(
                request: request(trailing: " after the caret"),
                settings: AppSettings()))
    }

    func testFingerprintIgnoresOnlyLivePrefixAndGenerationForTypeThroughReuse() {
        let settings = AppSettings()
        let original = CotypingSuggestionCacheFingerprint.make(
            request: request(prefix: "Hello", generation: 1),
            settings: settings)
        let typedThrough = CotypingSuggestionCacheFingerprint.make(
            request: request(prefix: "Hello wo", generation: 2),
            settings: settings)

        XCTAssertEqual(original, typedThrough)
    }
}
