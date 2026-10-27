import XCTest
@testable import LokalBot

/// Reading values typed in a terminal, mapping them to stored values, and
/// deciding which changes need the person.
final class SettingChangeTests: XCTestCase {
    private func spec(_ key: String) throws -> SettingSpec {
        try XCTUnwrap(SettingRegistry.spec(for: key), key)
    }

    private func code(_ body: () throws -> Any) -> String? {
        do {
            _ = try body()
            return nil
        } catch {
            return (error as? AppControlError)?.code ?? "\(error)"
        }
    }

    func testParsesCommandLineValuesByKind() throws {
        XCTAssertEqual(try spec("menuBarOnly").parse("off"), false)
        XCTAssertEqual(try spec("menuBarOnly").parse("YES"), true)
        XCTAssertEqual(code { try self.spec("menuBarOnly").parse("maybe") }, "invalid_value")
        XCTAssertEqual(try spec("dayDigestHour").parse("19"), 19)
        XCTAssertEqual(try spec("speechSpeed").parse("1.5"), .number(1.5))
        XCTAssertEqual(try spec("enabledMemoryRoutines").parse("dailyStandup, localJournal"), ["dailyStandup", "localJournal"])
        XCTAssertEqual(try spec("approvedRemoteInferenceOrigins").parse("[\"https://a.example\"]"), ["https://a.example"])
        XCTAssertEqual(try spec("openAIBaseURL").parse("  http://host/v1 "), "http://host/v1")
        XCTAssertEqual(try spec("dayDigestCustomPrompt").parse(" keep spaces "), " keep spaces ")
        XCTAssertEqual(code { try self.spec("dictationShortcut").parse("ctrl+space") }, "invalid_value")
    }

    func testMapsTokensToStoredValuesAndChecksRanges() throws {
        XCTAssertEqual(try spec("autoRecordMode").stored(fromPresented: "manual"), "Never auto-record")
        XCTAssertEqual(code { try self.spec("autoRecordMode").stored(fromPresented: "Never auto-record") }, "invalid_value")
        XCTAssertEqual(try spec("cotypingAcceptKey").stored(fromPresented: "rightArrow"), 124)
        XCTAssertEqual(code { try self.spec("dayDigestHour").stored(fromPresented: 24) }, "invalid_value")
        XCTAssertEqual(code { try self.spec("speechSpeed").stored(fromPresented: .number(3)) }, "invalid_value")
        XCTAssertEqual(try spec("enabledMemoryRoutines").stored(fromPresented: ["dailyStandup", "dailyStandup"]), ["dailyStandup"])
        XCTAssertEqual(code { try self.spec("noteTemplate").stored(fromPresented: true) }, "invalid_value")
    }

    func testClassifiesWideningAndNarrowing() throws {
        XCTAssertEqual(try spec("appTheme").classify(from: "system", to: "dark"), .preference)
        XCTAssertEqual(try spec("appTheme").classify(from: "dark", to: "dark"), .unchanged)
        XCTAssertEqual(try spec("customBuiltInModels").classify(from: [], to: [["id": "x"]]), .readOnly)
        XCTAssertEqual(try spec("trackingEnabled").classify(from: false, to: true), .widening)
        XCTAssertEqual(try spec("trackingEnabled").classify(from: true, to: false), .narrowing)
        XCTAssertEqual(try spec("requireCalendarForBrowser").classify(from: true, to: false), .widening)
        XCTAssertEqual(try spec("requireCalendarForBrowser").classify(from: false, to: true), .narrowing)
        XCTAssertEqual(try spec("autoRecordMode").classify(from: "Ask via notification", to: "Record automatically"), .widening)
        XCTAssertEqual(try spec("autoRecordMode").classify(from: "Record automatically", to: "Never auto-record"), .narrowing)
        XCTAssertEqual(try spec("screenContextCaptureMode").classify(from: "Activity only", to: "Text context"), .widening)
        XCTAssertEqual(try spec("screenContextCaptureMode").classify(from: "Text + visual context", to: "Text context"), .narrowing)
        XCTAssertEqual(try spec("excludedApps").classify(from: "1Password, Bitwarden", to: "1Password, Bitwarden, Slack"), .narrowing)
        XCTAssertEqual(try spec("excludedApps").classify(from: "1Password, Bitwarden", to: "bitwarden"), .widening)
        XCTAssertEqual(try spec("approvedRemoteInferenceOrigins").classify(from: ["https://a"], to: ["https://a", "https://b"]), .widening)
        XCTAssertEqual(try spec("approvedRemoteInferenceOrigins").classify(from: ["https://a", "https://b"], to: ["https://A"]), .narrowing)
        XCTAssertEqual(try spec("dailyMemoryExportFolder").classify(from: "", to: "/Users/me/Notes"), .widening)
        XCTAssertEqual(try spec("dailyMemoryExportFolder").classify(from: "/x", to: ""), .narrowing)
        XCTAssertEqual(try spec("retentionDays").classify(from: 14, to: 7), .widening)
        XCTAssertEqual(try spec("retentionDays").classify(from: 14, to: 30), .widening)
        XCTAssertEqual(try spec("openRouterDataPolicy").classify(from: "privateOnly", to: "accountPolicy"), .widening)
        XCTAssertEqual(try spec("openRouterDataPolicy").classify(from: "accountPolicy", to: "privateOnly"), .narrowing)
        XCTAssertEqual(try spec("modelDownloadSource").classify(from: "huggingFace", to: "hfMirror"), .widening)
        XCTAssertEqual(try spec("modelDownloadSource").classify(from: "hfMirror", to: "modelScope"), .widening)
        XCTAssertEqual(try spec("modelDownloadSource").classify(from: "modelScope", to: "hfMirror"), .narrowing)
        XCTAssertEqual(try spec("modelDownloadSource").classify(from: "hfMirror", to: "huggingFace"), .narrowing)
    }

    func testEveryConsentSettingHasADirection() throws {
        // A consent setting with no rule would treat every change as widening,
        // including turning it off. Check each one can be narrowed.
        let defaults = AppControlHandler.encoded(AppSettings())
        for spec in SettingRegistry.all where spec.tier == .consent {
            let narrowed: JSONValue
            switch (spec.key, spec.kind) {
            case ("retentionDays", _), ("keepOCRTextForever", _):
                continue // both directions need review, on purpose
            case ("requireCalendarForBrowser", _): narrowed = true
            case ("autoRecordMode", _): narrowed = "Never auto-record"
            case ("screenContextCaptureMode", _): narrowed = "Activity only"
            case ("openRouterDataPolicy", _): narrowed = "privateOnly"
            case ("modelDownloadSource", _): narrowed = "huggingFace"
            case (_, .bool): narrowed = false
            case (_, .text(.commaSeparated)):
                // Adding an exclusion narrows; clearing the list would widen.
                narrowed = .string((defaults[spec.key]?.stringValue ?? "") + ", Example App")
            case (_, .text): narrowed = ""
            case (_, .textList): narrowed = []
            default:
                XCTFail("\(spec.key) has no narrowing rule")
                continue
            }
            let current = defaults[spec.key] ?? .null
            let change = spec.classify(from: current, to: narrowed)
            XCTAssertTrue(change == .narrowing || change == .unchanged, "\(spec.key): \(change)")
        }
    }

    func testRequestParamsRoundTrip() throws {
        XCTAssertEqual(code { try SettingsChangeRequest(params: [:]) }, "invalid_request")
        XCTAssertEqual(code { try SettingsChangeRequest(params: ["changes": ["a": 1], "reset": ["a"]]) }, "invalid_request")
        let request = try SettingsChangeRequest(params: [
            "changes": ["appTheme": "dark"], "reset": ["dayDigestHour"], "dryRun": true,
        ])
        XCTAssertTrue(request.dryRun)
        XCTAssertEqual(try SettingsChangeRequest(params: request.params), request)
    }

    func testPlanResetsToDefaultsAndKeepsRedactedURLParts() throws {
        let current: [String: JSONValue] = [
            "appTheme": "system", "trackingEnabled": true, "dayDigestHour": 20,
            "openAIBaseURL": "https://user:secret@host.example/v1?key=1",
        ]
        let defaults: [String: JSONValue] = ["appTheme": "system", "trackingEnabled": true, "dayDigestHour": 18]
        let plan = try SettingsChangePlan.make(
            request: SettingsChangeRequest(changes: ["appTheme": "dark", "trackingEnabled": false], reset: ["dayDigestHour"]),
            current: current, defaults: defaults)
        XCTAssertEqual(plan.items.map(\.spec.key), ["appTheme", "trackingEnabled", "dayDigestHour"])
        XCTAssertEqual(plan.items.last?.stored, 18)
        XCTAssertEqual(plan.applicable.count, 3)

        // `config export` shows the URL redacted; importing it back is a no-op.
        let url = try SettingsChangePlan.make(
            request: SettingsChangeRequest(changes: ["openAIBaseURL": "https://host.example/v1"]),
            current: current, defaults: defaults, redactURL: DiagnosticsSettingsSanitizer.redactURL)
        XCTAssertEqual(url.items.first?.change, .unchanged)
        XCTAssertEqual(url.items.first?.stored, "https://user:secret@host.example/v1?key=1")

        XCTAssertThrowsError(try SettingsChangePlan.make(
            request: SettingsChangeRequest(changes: ["languageHint": "en"]), current: current, defaults: defaults)) { error in
            XCTAssertEqual((error as? AppControlError)?.code, "unknown_key")
        }
    }
}
