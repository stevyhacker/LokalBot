import XCTest
@testable import LokalBot

/// The NavSection migration mapping (spec §2.1): capture names from the
/// UI-test host env and deep links resolve to sections, with legacy
/// pre-merge names mapping onto the merged pillars.
final class NavSectionMappingTests: XCTestCase {

    func testCaptureNamesMapToTheirSections() {
        XCTAssertEqual(AppState.NavSection(captureName: "timeline"), .timeline)
        XCTAssertEqual(AppState.NavSection(captureName: "meetings"), .meetings)
        XCTAssertEqual(AppState.NavSection(captureName: "people"), .people)
        XCTAssertEqual(AppState.NavSection(captureName: "Projects"), .projects)
        XCTAssertEqual(AppState.NavSection(captureName: "type"), .settings)
        XCTAssertEqual(AppState.NavSection(captureName: "ask"), .ask)
        XCTAssertEqual(AppState.NavSection(captureName: "settings"), .settings)
    }

    /// Spec §2.5: Settings absorbs Models — the legacy "models" capture name
    /// lands on Settings, and the SettingsTab mapping preselects its tab.
    func testLegacyModelsNameMapsToSettings() {
        XCTAssertEqual(AppState.NavSection(captureName: "models"), .settings)
        XCTAssertEqual(AppState.NavSection(captureName: "Models"), .settings)
    }

    /// Settings opens on Overview with General right under it, above the
    /// headings, and every other page sits under one sidebar heading, in the
    /// order the sidebar shows them.
    func testSettingsPagesAreGroupedByFeature() {
        let pages = AppState.SettingsTab.allCases
        XCTAssertEqual(Array(pages.prefix(2)), [.overview, .general])
        XCTAssertNil(AppState.SettingsTab.overview.group)
        XCTAssertNil(AppState.SettingsTab.general.group)
        XCTAssertTrue(pages.dropFirst(2).allSatisfy { $0.group != nil })
        let order = pages.compactMap(\.group)
        XCTAssertEqual(order, order.sorted { lhs, rhs in
            AppState.SettingsTab.Group.allCases.firstIndex(of: lhs)! < AppState.SettingsTab.Group.allCases.firstIndex(of: rhs)!
        }, "a heading's pages are listed together")
        XCTAssertEqual(Set(pages.map(\.displayName)).count, pages.count)
        XCTAssertEqual(AppState.SettingsTab.dayMemory.displayName, "Screen & Activity")
        XCTAssertEqual(AppState.SettingsTab.writing.displayName, "Autocomplete")
    }

    func testSettingsTabCaptureNamesSelectTheTab() {
        XCTAssertEqual(AppState.SettingsTab(captureName: "models"), .models)
        XCTAssertEqual(AppState.SettingsTab(captureName: "general"), .general)
        XCTAssertEqual(AppState.SettingsTab(captureName: "recording"), .recording)
        XCTAssertEqual(AppState.SettingsTab(captureName: "dictation"), .dictation)
        XCTAssertEqual(AppState.SettingsTab(captureName: "privacy"), .privacy)
        XCTAssertEqual(AppState.SettingsTab(captureName: "advanced"), .advanced)
        // Pages renamed when Settings was organized by feature keep their
        // old names, and the new pages have their own.
        XCTAssertEqual(AppState.SettingsTab(captureName: "day memory"), .dayMemory)
        XCTAssertEqual(AppState.SettingsTab(captureName: "screen"), .dayMemory)
        XCTAssertEqual(AppState.SettingsTab(captureName: "writing"), .writing)
        XCTAssertEqual(AppState.SettingsTab(captureName: "autocomplete"), .writing)
        XCTAssertEqual(AppState.SettingsTab(captureName: "diagnostics"), .advanced)
        XCTAssertEqual(AppState.SettingsTab(captureName: "overview"), .overview)
        XCTAssertEqual(AppState.SettingsTab(captureName: "files"), .files)
        XCTAssertEqual(AppState.SettingsTab(captureName: "email"), .email)
        XCTAssertEqual(AppState.SettingsTab(captureName: "daily review"), .daily)
        XCTAssertEqual(AppState.SettingsTab(captureName: "external agents"), .agents)
        XCTAssertNil(AppState.SettingsTab(captureName: "settings"))
        XCTAssertNil(AppState.SettingsTab(captureName: "capture"))
    }

    /// The pre-split merged "capture" section name lands on Timeline.
    func testLegacyCaptureNameMapsToTimeline() {
        XCTAssertEqual(AppState.NavSection(captureName: "capture"), .timeline)
        XCTAssertEqual(AppState.NavSection(captureName: "Capture"), .timeline)
    }

    func testLegacyTypeNamesMapToSettings() {
        XCTAssertEqual(AppState.NavSection(captureName: "dictation"), .settings)
        XCTAssertEqual(AppState.NavSection(captureName: "Cotyping"), .settings)
    }

    func testLegacySearchAndChatNamesMapToAsk() {
        XCTAssertEqual(AppState.NavSection(captureName: "search"), .ask)
        XCTAssertEqual(AppState.NavSection(captureName: "chat"), .ask)
        XCTAssertEqual(AppState.NavSection(captureName: "Search"), .ask)
    }

    func testUnknownNameIsNil() {
        XCTAssertNil(AppState.NavSection(captureName: "bogus"))
        XCTAssertNil(AppState.NavSection(captureName: ""))
    }

    func testTypeTabCaptureNamesSelectTheTab() {
        XCTAssertEqual(AppState.TypeTab(captureName: "dictation"), .dictation)
        XCTAssertEqual(AppState.TypeTab(captureName: "Cotyping"), .cotyping)
        XCTAssertNil(AppState.TypeTab(captureName: "type"))
        XCTAssertNil(AppState.TypeTab(captureName: "capture"))
    }

    func testTodayCaptureNameMapsToToday() {
        XCTAssertEqual(AppState.NavSection(captureName: "today"), .today)
        XCTAssertEqual(AppState.NavSection(captureName: "Today"), .today)
    }
}

/// Agent Mode's sidebar section (Task 16): the "agent" capture name resolves
/// to its NavSection so deep links and the UI-test host can land on it.
final class NavSectionAgentTests: XCTestCase {
    func testAgentSectionRoundTripsCaptureName() {
        XCTAssertEqual(AppState.NavSection(captureName: "agent"), .agent)
        XCTAssertEqual(AppState.NavSection(captureName: "Agent"), .agent)
    }
}

/// The ruling's landing surface: a fresh state opens on Today, the
/// glanceable summary — not on the forensic Timeline.
@MainActor
final class TodayLandingTests: XCTestCase {
    func testFreshAppStateLandsOnToday() {
        XCTAssertEqual(AppState().navSection, .today)
    }
}
