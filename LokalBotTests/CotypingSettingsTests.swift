import AppKit
import XCTest
@testable import LokalBot

// MARK: - Settings codec

final class CotypingSettingsTests: XCTestCase {
    func testHybridDefaultsOffAndRoundTripsBothDirections() throws {
        XCTAssertFalse(AppSettings().cotypingSelectiveOneWordHybrid)
        XCTAssertFalse(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).cotypingSelectiveOneWordHybrid)
        var settings = AppSettings()
        for enabled in [true, false] {
            settings.cotypingSelectiveOneWordHybrid = enabled
            let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
            XCTAssertEqual(decoded.cotypingSelectiveOneWordHybrid, enabled)
        }
    }

    func testDefaultsDisabled() {
        XCTAssertFalse(AppSettings().cotypingEnabled)
    }

    func testRoundTripsCotypingFields() throws {
        var settings = AppSettings()
        settings.cotypingEnabled = true
        settings.cotypingUserName = "Ada"
        settings.cotypingMaxWords = 12
        settings.cotypingMultiLine = true
        settings.cotypingDebounceMs = 500
        settings.cotypingAcceptGranularity = .phrase
        settings.cotypingFullAcceptKey = .rightArrow
        settings.cotypingAutoAcceptTrailingPunctuation = true
        settings.cotypingEscapeBehavior = .passThrough
        settings.cotypingAddSpaceAfterAccept = true
        settings.cotypingExcludedApps = "Terminal, 1Password"
        settings.cotypingSuggestInIntegratedTerminals = true
        settings.cotypingBuiltInModelID = ModelCatalog.compactFallbackID
        settings.cotypingUseLocalLearning = false
        settings.cotypingLearningExamplesInPrompt = 5

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertTrue(decoded.cotypingEnabled)
        XCTAssertEqual(decoded.cotypingUserName, "Ada")
        XCTAssertEqual(decoded.cotypingMaxWords, 12)
        XCTAssertTrue(decoded.cotypingMultiLine)
        XCTAssertEqual(decoded.cotypingDebounceMs, 500)
        XCTAssertEqual(decoded.cotypingAcceptGranularity, .phrase)
        XCTAssertEqual(decoded.cotypingFullAcceptKey, .rightArrow)
        XCTAssertTrue(decoded.cotypingAutoAcceptTrailingPunctuation)
        XCTAssertEqual(decoded.cotypingEscapeBehavior, .passThrough)
        XCTAssertTrue(decoded.cotypingAddSpaceAfterAccept)
        XCTAssertEqual(decoded.cotypingExcludedAppList, ["Terminal", "1Password"])
        XCTAssertTrue(decoded.cotypingSuggestInIntegratedTerminals)
        XCTAssertEqual(decoded.cotypingBuiltInModelID, ModelCatalog.compactFallbackID)
        XCTAssertFalse(decoded.cotypingUseLocalLearning)
        XCTAssertEqual(decoded.cotypingLearningExamplesInPrompt, 5)
    }

    func testLegacyDefaultDebounceMigratesToCurrentLatencyTarget() throws {
        let data = #"{"cotypingDebounceMs":350}"#.data(using: .utf8)!
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(settings.cotypingDebounceMs, AppSettings.defaultCotypingDebounceMs)
    }

    func testUnversionedPreviewDefaultsMigrateToCurrentTargets() throws {
        let data = #"{"cotypingDebounceMs":150,"cotypingMaxWords":2}"#.data(using: .utf8)!
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(settings.cotypingDebounceMs, AppSettings.defaultCotypingDebounceMs)
        XCTAssertEqual(settings.cotypingMaxWords, AppSettings().cotypingMaxWords)
    }

    func testVersionedShortCustomCotypingValuesArePreserved() throws {
        let data = #"{"cotypingSettingsVersion":3,"cotypingDebounceMs":120,"cotypingMaxWords":2}"#.data(using: .utf8)!
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(settings.cotypingDebounceMs, 120)
        XCTAssertEqual(settings.cotypingMaxWords, 2)
    }

    func testPreviousLowLatencyDefaultMigratesToCurrentResourceFriendlyDefault() throws {
        let data = #"{"cotypingSettingsVersion":2,"cotypingDebounceMs":20}"#.data(using: .utf8)!
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(settings.cotypingDebounceMs, AppSettings.defaultCotypingDebounceMs)
    }

    func testLegacyCustomDebounceIsPreservedWithinSupportedRange() throws {
        let data = #"{"cotypingDebounceMs":500}"#.data(using: .utf8)!
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(settings.cotypingDebounceMs, 500)
    }

    func testCotypingDebounceDecodeClampsToSupportedRange() throws {
        let tooLow = #"{"cotypingSettingsVersion":1,"cotypingDebounceMs":5}"#.data(using: .utf8)!
        XCTAssertEqual(
            try JSONDecoder().decode(AppSettings.self, from: tooLow).cotypingDebounceMs,
            CotypingDebouncePolicy.minimumMilliseconds)

        let tooHigh = #"{"cotypingSettingsVersion":1,"cotypingDebounceMs":2000}"#.data(using: .utf8)!
        XCTAssertEqual(
            try JSONDecoder().decode(AppSettings.self, from: tooHigh).cotypingDebounceMs,
            AppSettings.maximumCotypingDebounceMs)
    }

    func testTolerantDecodeKeepsOtherDefaults() throws {
        let data = #"{"cotypingEnabled":true}"#.data(using: .utf8)!
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertTrue(settings.cotypingEnabled)
        XCTAssertEqual(settings.cotypingMaxWords, AppSettings().cotypingMaxWords)
        XCTAssertEqual(settings.cotypingDebounceMs, AppSettings().cotypingDebounceMs)
        XCTAssertFalse(settings.cotypingAutoAcceptTrailingPunctuation)
        XCTAssertFalse(settings.cotypingAddSpaceAfterAccept)
        XCTAssertTrue(settings.cotypingUseLocalLearning)
        XCTAssertEqual(settings.cotypingBuiltInModelID, "gemma4-e2b-base-q6")
        XCTAssertTrue(settings.menuBarOnly)
    }

    func testSavedAutocompleteModelSelectionIsPreserved() throws {
        for modelID in ["lfm2.5-1.2b-instruct", "custom-autocomplete"] {
            let data = try JSONSerialization.data(withJSONObject: ["cotypingBuiltInModelID": modelID])
            let settings = try JSONDecoder().decode(AppSettings.self, from: data)
            XCTAssertEqual(settings.cotypingBuiltInModelID, modelID)
        }
    }

    func testInProcessRuntimeDefaultsOn() {
        XCTAssertTrue(AppSettings().cotypingInProcessRuntime)
    }

    func testInProcessRuntimeRoundTrips() throws {
        var settings = AppSettings()
        settings.cotypingInProcessRuntime = false
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertFalse(decoded.cotypingInProcessRuntime)
    }

    func testTolerantDecodeDefaultsInProcessRuntimeOn() throws {
        // A saved blob predating the flag must decode with the default (true).
        let json = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertTrue(decoded.cotypingInProcessRuntime)
    }

    func testDefaultsKeepCotypingSuggestionsConcise() {
        let settings = AppSettings()
        XCTAssertEqual(settings.cotypingMaxWords, 4)
        XCTAssertEqual(settings.cotypingDebounceMs, 160)
        XCTAssertFalse(settings.cotypingAutoAcceptTrailingPunctuation)
        XCTAssertFalse(settings.cotypingAddSpaceAfterAccept)
        XCTAssertEqual(settings.cotypingMaxResponseTokens, 6)
    }

    /// Version 4 moved two defaults to what Cotypist does. Settings saved by
    /// an earlier build follow; a value chosen since then is kept.
    func testEarlierDefaultsMoveToTheCotypistOnesOnce() throws {
        let earlier = #"{"cotypingSettingsVersion":3,"cotypingMaxWords":3,"cotypingAutoAcceptTrailingPunctuation":true}"#
        let migrated = try JSONDecoder().decode(AppSettings.self, from: Data(earlier.utf8))
        XCTAssertEqual(migrated.cotypingMaxWords, 4)
        XCTAssertFalse(migrated.cotypingAutoAcceptTrailingPunctuation)

        let customLength = #"{"cotypingSettingsVersion":3,"cotypingMaxWords":6}"#
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: Data(customLength.utf8)).cotypingMaxWords, 6)

        let chosen = #"{"cotypingSettingsVersion":4,"cotypingMaxWords":3,"cotypingAutoAcceptTrailingPunctuation":true}"#
        let kept = try JSONDecoder().decode(AppSettings.self, from: Data(chosen.utf8))
        XCTAssertEqual(kept.cotypingMaxWords, 3)
        XCTAssertTrue(kept.cotypingAutoAcceptTrailingPunctuation)

        // Saving stamps the current version, so the move happens only once.
        var saved = migrated
        saved.cotypingMaxWords = 3
        let reloaded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(reloaded.cotypingMaxWords, 3)
    }

    func testMaxResponseTokensMirrorCotypistBudget() {
        var settings = AppSettings()
        settings.cotypingMaxWords = 2
        XCTAssertEqual(settings.cotypingMaxResponseTokens, 5)   // floor
        settings.cotypingMaxWords = 8
        XCTAssertEqual(settings.cotypingMaxResponseTokens, 11)  // ceil(8 * 1.3)
        settings.cotypingMaxWords = 20
        XCTAssertEqual(settings.cotypingMaxResponseTokens, 26)  // ceil(20 * 1.3)
        settings.cotypingMultiLine = true
        XCTAssertEqual(settings.cotypingMaxResponseTokens, 52)  // doubled for multiline
        settings.cotypingMaxWords = 100
        XCTAssertEqual(settings.cotypingMaxResponseTokens, 120) // cap
    }
}
