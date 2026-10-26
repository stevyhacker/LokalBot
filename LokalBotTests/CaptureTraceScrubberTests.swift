import XCTest
@testable import LokalBot

final class CaptureTraceScrubberTests: XCTestCase {
    private let scrubber = CaptureTraceScrubber(key: 42)
    private let vowels = CharacterSet(charactersIn: "aeiouyAEIOUY")

    private func isScrubbed(_ text: String) -> Bool {
        let tokens = text.split { !($0.isLetter || $0.isNumber) }.map(String.init)
        return tokens.allSatisfy { token in
            CaptureTraceScrubber.allowlist.vocabulary.contains(token.lowercased())
                || (token.unicodeScalars.allSatisfy(\.isASCII)
                    && token.rangeOfCharacter(from: vowels) == nil)
        }
    }

    func testTextKeepsVocabularyStructureAndPunctuationButNotContent() {
        let output = scrubber.scrubText("Meet - Quarterly revenue review (draft 3)")
        XCTAssertTrue(output.hasPrefix("Meet - "))
        XCTAssertEqual(output.count, "Meet - Quarterly revenue review (draft 3)".count)
        XCTAssertFalse(output.contains("revenue"))
        XCTAssertTrue(isScrubbed(output))
        XCTAssertEqual(scrubber.scrubText("revenue"), scrubber.scrubText("revenue"), "deterministic per key")
    }

    func testMeetCodesKeepTheirShape() {
        let output = scrubber.scrubURL("https://meet.google.com/abc-defg-hij?authuser=2#x")
        XCTAssertNotNil(BrowserMeetingSession.meetURL(output), output)
        XCTAssertFalse(output.contains("abc-defg-hij"))
        XCTAssertFalse(output.contains("authuser"))
    }

    func testScrubberReplacesNonASCIIAndStripsEmailsAndQueries() {
        let text = scrubber.scrubText("Sastanak sa Đorđem 🎉 日本語 ana@firma.rs")
        XCTAssertFalse(text.contains("Đorđem"))
        XCTAssertFalse(text.contains("ana@firma.rs"))
        XCTAssertFalse(text.contains("🎉"))
        XCTAssertTrue(isScrubbed(text), text)
        let url = scrubber.scrubURL("https://user:pw@docs.example.com/d/Plan%20Q3/edit?usp=ana@firma.rs")
        XCTAssertFalse(url.contains("pw"))
        XCTAssertFalse(url.contains("usp"))
        XCTAssertFalse(url.contains("firma"))
        XCTAssertFalse(url.contains("example"))
    }

    func testBundleIDsKeepOnlyDetectionAppsAndTheirHelpers() {
        XCTAssertEqual(scrubber.scrubBundleID("com.google.Chrome.helper"), "com.google.Chrome.helper")
        XCTAssertEqual(scrubber.scrubBundleID("com.apple.dt.Xcode"), "com.apple.dt.Xcode")
        let scrubbed = scrubber.scrubBundleID("com.acme.payroll")
        XCTAssertNotEqual(scrubbed, "com.acme.payroll")
        XCTAssertTrue(isScrubbed(scrubbed), scrubbed)
        XCTAssertEqual(scrubbed.split(separator: ".").count, 3, "the shape survives")
    }

    func testEveryDetectionBundleIDSurvivesScrubbing() {
        let detection = Array(MeetingDetector.knownApps.keys) + Array(MeetingDetector.browsers)
            + Array(MeetingDetector.alwaysOpenAudioBundles)
        for id in detection {
            XCTAssertEqual(scrubber.scrubBundleID(id), id)
        }
    }

    /// Helpers outside their host's namespace need their own entries, or a
    /// recorded Feishu or DingTalk trace loses the process that carries the call.
    func testForeignMeetingHelpersSurviveScrubbing() {
        for helper in ["com.bytedance.lark.helper", "com.bytedance.lark.helper.Renderer",
                       "com.alibaba.DingTalk-Helper", "Cisco-Systems.SparkHelper"] {
            XCTAssertEqual(scrubber.scrubBundleID(helper), helper)
            XCTAssertTrue(MeetingDetector.foreignHelperHosts.keys.contains { helper.lowercased().hasPrefix($0) },
                          helper)
        }
        XCTAssertEqual(scrubber.scrubAppName("腾讯会议"), "腾讯会议")
        XCTAssertEqual(scrubber.scrubAppName("飞书"), "飞书")
    }

    func testKnownAppNamesSurviveAndUnknownOnesDoNot() {
        XCTAssertEqual(scrubber.scrubAppName("Google Chrome"), "Google Chrome")
        XCTAssertNotEqual(scrubber.scrubAppName("Acme Payroll"), "Acme Payroll")
    }

    func testSwiftAllowlistMatchesTheSharedJSON() throws {
        let json = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Scripts/record-capture/scrub-allowlist.json")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any])
        XCTAssertEqual(object["scrubberVersion"] as? Int, CaptureTraceScrubber.version)
        XCTAssertEqual(Set(object["vocabulary"] as? [String] ?? []), CaptureTraceScrubber.allowlist.vocabulary)
        XCTAssertEqual(Set(object["appNames"] as? [String] ?? []), CaptureTraceScrubber.allowlist.appNames)
        XCTAssertEqual(Set(object["meetingHosts"] as? [String] ?? []), CaptureTraceScrubber.allowlist.meetingHosts)
        XCTAssertEqual(Set(object["bundleIDs"] as? [String] ?? []), CaptureTraceScrubber.allowlist.bundleIDs)
        XCTAssertEqual(object["bundlePrefixes"] as? [String] ?? [], CaptureTraceScrubber.allowlist.bundlePrefixes)
    }

    func testRecorderWritesOnlyScrubbedTraces() async throws {
        struct Workspace: WorkspaceSource {
            func frontmostApplication() -> RunningApp? {
                RunningApp(processIdentifier: 9, bundleIdentifier: "com.acme.payroll", localizedName: "Acme Payroll")
            }
            func runningApplications() -> [RunningApp] { [] }
            func isRunning(processID: pid_t) -> Bool { true }
            func secondsSinceLastInput() -> TimeInterval { 0 }
        }
        var base = CaptureEnvironment.live
        base.workspace = Workspace()
        let recorder = CaptureTraceRecorder(scenario: "test", origin: .scripted, base: base)
        _ = recorder.environment.workspace.frontmostApplication()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("traces-\(UUID())")
        let trace = try CaptureTrace.load(from: recorder.finish(to: folder))
        XCTAssertEqual(trace.header.scrubberVersion, CaptureTraceScrubber.version)
        let name = try XCTUnwrap(trace.events.first?.app?.localizedName)
        XCTAssertNotEqual(name, "Acme Payroll")
        XCTAssertTrue(isScrubbed(name), name)
        let bundleID = try XCTUnwrap(trace.events.first?.app?.bundleIdentifier)
        XCTAssertNotEqual(bundleID, "com.acme.payroll")
    }
}
