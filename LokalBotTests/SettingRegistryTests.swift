import XCTest
@testable import LokalBot

/// Keeps the terminal's settings registry identical to `AppSettings`: every
/// stored key described, every choice spelled as the real enum stores it.
@MainActor
final class SettingRegistryTests: XCTestCase {
    private func encodedKeys(_ settings: AppSettings) throws -> Set<String> {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings))
        return Set(try XCTUnwrap(object as? [String: Any]).keys)
    }

    private func stored<T: Encodable>(_ values: [T]) throws -> [JSONValue] {
        try values.map { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode($0)) }
    }

    func testEveryStoredKeyHasExactlyOneSpecOrIsInternal() throws {
        var settings = AppSettings()
        // Optional keys are encoded only when set.
        settings.agentReasoningLevel = .low
        settings.dreamingFirstEligibleDayKey = "2026-01-01"
        let stored = try encodedKeys(settings)
        let specKeys = SettingRegistry.all.map(\.key)

        XCTAssertEqual(specKeys.count, Set(specKeys).count, "duplicate keys in SettingRegistry")
        XCTAssertTrue(Set(specKeys).isDisjoint(with: SettingRegistry.internalKeys))
        XCTAssertEqual(stored.subtracting(SettingRegistry.internalKeys), Set(specKeys),
                       "add new AppSettings keys to SettingRegistry, or list bookkeeping keys in internalKeys")
    }

    func testChoicesMatchTheRealEnums() throws {
        let expected: [String: [JSONValue]] = [
            "autoRecordMode": try stored(AppSettings.AutoRecordMode.allCases),
            "appTheme": try stored(AppTheme.allCases),
            "appLanguage": try stored(AppLanguage.allCases),
            "textSize": try stored(AppTextSize.allCases),
            "noteTemplate": try stored(NoteTemplate.allCases),
            "diarizationModel": try stored(DiarizationModel.allCases),
            "screenContextCaptureMode": try stored(AppSettings.ScreenContextCaptureMode.allCases),
            "dailyMemoryExportFormat": try stored(AppSettings.DailyMemoryExportFormat.allCases),
            "enabledMemoryRoutines": try stored(AppSettings.MemoryRoutineKind.allCases),
            "transcriptionModel": try stored(TranscriptionModelChoice.allCases),
            "speechVoice": try stored(KokoroVoice.allCases),
            "summarizerBackend": try stored(AppSettings.SummarizerBackend.allCases),
            "openRouterDataPolicy": try stored(OpenRouterDataPolicy.allCases),
            "generationBudgetPreset": try stored(GenerationBudgetPreset.allCases),
            "thinkReasoningLevel": try stored(ThinkReasoningLevel.allCases),
            "agentReasoningLevel": try stored(ThinkReasoningLevel.allCases),
            "cotypingBackend": try stored(CotypingBackend.allCases),
            "cotypingServerRequestStyle": try stored(CotypingServerRequestStyle.allCases),
            "cotypingAcceptGranularity": try stored(CotypingAcceptGranularity.allCases),
            "cotypingAcceptKey": try stored(CotypingAcceptKey.allCases),
            "cotypingFullAcceptKey": try stored([CotypingFullAcceptKey.backtick, .rightArrow, .off]),
            "cotypingEscapeBehavior": try stored(CotypingEscapeBehavior.allCases),
            "cotypingMirrorPreference": try stored([CotypingMirrorPreference.auto, .alwaysInline, .alwaysMirror]),
            "dictationIntent": try stored(DictationIntent.allCases),
            "dictationTriggerMode": try stored(DictationTriggerMode.allCases),
            "dictationOutputMode": try stored(DictationOutputMode.allCases),
        ]
        let choiceSpecs = SettingRegistry.all.filter { $0.kind.choices != nil }
        XCTAssertEqual(Set(choiceSpecs.map(\.key)), Set(expected.keys))
        for spec in choiceSpecs {
            let choices = try XCTUnwrap(spec.kind.choices)
            XCTAssertEqual(choices.map(\.stored), expected[spec.key], spec.key)
            XCTAssertEqual(choices.count, Set(choices.map(\.token)).count, "duplicate tokens in \(spec.key)")
        }
    }

    func testDefaultsFitTheirKinds() throws {
        let defaults = AppControlHandler.encoded(AppSettings())
        for spec in SettingRegistry.all {
            guard let value = defaults[spec.key] else {
                XCTAssertEqual(spec.key, "agentReasoningLevel", "\(spec.key) has no encoded default")
                continue
            }
            switch spec.kind {
            case .bool:
                guard case .bool = value else { XCTFail("\(spec.key) is not a boolean"); continue }
            case .integer(let range):
                let number = try XCTUnwrap(value.intValue, spec.key)
                if let range { XCTAssertTrue(range.contains(number), spec.key) }
            case .number(let range):
                guard case .number(let number) = value else { XCTFail("\(spec.key) is not a number"); continue }
                if let range { XCTAssertTrue(range.contains(number), spec.key) }
            case .text:
                XCTAssertNotNil(value.stringValue, spec.key)
            case .textList:
                guard case .array(let items) = value else { XCTFail("\(spec.key) is not a list"); continue }
                XCTAssertTrue(items.allSatisfy { $0.stringValue != nil }, spec.key)
            case .choice(let choices):
                XCTAssertTrue(choices.contains { $0.stored == value }, "\(spec.key) default \(value) is not a choice")
            case .choiceList(let choices):
                guard case .array(let items) = value else { XCTFail("\(spec.key) is not a list"); continue }
                XCTAssertTrue(items.allSatisfy { item in choices.contains { $0.stored == item } }, spec.key)
            case .structured:
                break
            }
        }
    }

    func testRangesMatchTheDecoderClamps() {
        XCTAssertEqual(SettingRegistry.spec(for: "stopDebounceSeconds")?.kind,
                       .number(AppSettings.minimumStopDebounceSeconds...AppSettings.maximumStopDebounceSeconds))
        XCTAssertEqual(SettingRegistry.spec(for: "speechSpeed")?.kind,
                       .number(AppSettings.minimumSpeechSpeed...AppSettings.maximumSpeechSpeed))
        XCTAssertEqual(SettingRegistry.spec(for: "cotypingDebounceMs")?.kind,
                       .integer(CotypingDebouncePolicy.minimumMilliseconds...AppSettings.maximumCotypingDebounceMs))
    }

    func testSearchDescriptorsAgreeWithTheRegistry() {
        for descriptor in SettingDescriptor.all {
            let key = String(descriptor.id.dropFirst("settings.".count))
            guard let spec = SettingRegistry.spec(for: key) else { continue }
            XCTAssertEqual(spec.title, descriptor.title, key)
            XCTAssertEqual(spec.category.rawValue, descriptor.category.rawValue, key)
        }
        XCTAssertEqual(Set(SettingCategory.allCases.map(\.rawValue)),
                       Set(AppState.SettingsTab.allCases.map(\.rawValue)))
    }

    func testSchemaDescribesEveryKey() throws {
        let properties = try XCTUnwrap(SettingRegistry.jsonSchema["properties"]?.objectValue)
        XCTAssertEqual(Set(properties.keys), Set(SettingRegistry.all.map(\.key)))
        XCTAssertEqual(properties["autoRecordMode"]?["enum"], ["automatic", "ask", "manual"])
        XCTAssertEqual(properties["autoRecordMode"]?["x-lokalbot-tier"], "consent")
    }

    func testSearchFindsSettingsByPlainWords() {
        XCTAssertEqual(SettingRegistry.search("dark mode").first?.key, "appTheme")
        XCTAssertTrue(SettingRegistry.search("clipboard").map(\.key).contains("cotypingUseClipboard"))
        XCTAssertEqual(SettingRegistry.search("autoRecordMode").first?.key, "autoRecordMode")
    }

    func testSnapshotPresentsTokensAndRedactsURLs() throws {
        var settings = AppSettings()
        settings.appTheme = .dark
        settings.autoRecordMode = .manual
        settings.openAIBaseURL = "https://user:secret@example.com/v1?key=abc"
        let entries = SettingsSnapshot.entries(
            current: AppControlHandler.encoded(settings),
            defaults: AppControlHandler.encoded(AppSettings()),
            redactURL: DiagnosticsSettingsSanitizer.redactURL)
        func entry(_ key: String) throws -> JSONValue {
            try XCTUnwrap(entries.first { $0["key"]?.stringValue == key })
        }
        XCTAssertEqual(entries.count, SettingRegistry.all.count)
        XCTAssertEqual(try entry("appTheme")["value"], "dark")
        XCTAssertEqual(try entry("appTheme")["default"], "system")
        XCTAssertEqual(try entry("appTheme")["changed"], true)
        XCTAssertEqual(try entry("autoRecordMode")["value"], "manual")
        XCTAssertEqual(try entry("autoRecordMode")["default"], "ask")
        XCTAssertEqual(try entry("textSize")["changed"], false)
        XCTAssertEqual(try entry("openAIBaseURL")["value"], "https://example.com/v1")
        XCTAssertEqual(try entry("agentReasoningLevel")["value"], .null)
    }

    func testSnapshotSpecSelection() throws {
        XCTAssertEqual(try SettingsSnapshot.specs(category: "privacy", keys: nil).map(\.key),
                       ["retentionDays", "keepOCRTextForever", "excludedApps", "excludedScreenDomains"])
        XCTAssertEqual(try SettingsSnapshot.specs(category: nil, keys: ["appTheme"]).map(\.key), ["appTheme"])
        XCTAssertThrowsError(try SettingsSnapshot.specs(category: nil, keys: ["languageHint"])) { error in
            XCTAssertEqual((error as? AppControlError)?.code, "unknown_key")
        }
        XCTAssertThrowsError(try SettingsSnapshot.specs(category: "nope", keys: nil)) { error in
            XCTAssertEqual((error as? AppControlError)?.code, "invalid_request")
        }
    }
}
