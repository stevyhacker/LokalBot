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
        XCTAssertEqual(AppState.NavSection(captureName: "ask"), .ask)
    }

    /// Settings has its own window, so its names are no longer sections of
    /// the main window: they open Settings instead.
    func testSettingsNamesOpenTheSettingsWindow() {
        for name in ["settings", "Settings", "models", "Models", "type", "write", "dictation", "Cotyping",
                     "autocomplete", "overview", "general", "privacy", "agents", "files", "email", "diagnostics"] {
            XCTAssertNil(AppState.NavSection(captureName: name), name)
            XCTAssertTrue(AppState.SettingsTab.opensSettings(sectionName: name), name)
        }
    }

    /// Names shared with a main-window section stay with the main window.
    func testMainWindowSectionNamesDoNotOpenSettings() {
        for name in ["today", "actions", "meetings", "timeline", "capture", "people", "projects", "ask",
                     "search", "chat", "agent", "bogus", ""] {
            XCTAssertFalse(AppState.SettingsTab.opensSettings(sectionName: name), name)
        }
    }

    /// The Settings list: the LokalBot row opens Overview; General, Models
    /// and Privacy & permissions follow; then Remember, Assistant, Writing
    /// and Sharing; Diagnostics is last.
    func testSettingsPagesAreListedInTheApprovedOrder() {
        typealias Tab = AppState.SettingsTab
        XCTAssertEqual(Tab.allCases, [
            .overview, .general, .models, .privacy,
            .recording, .dayMemory, .files, .email,
            .ask, .personalContext, .daily,
            .writing, .dictation,
            .agents, .devices,
            .advanced,
        ])
        XCTAssertEqual(Tab.leadingPages, [.general, .models, .privacy])
        XCTAssertEqual(Tab.trailingPages, [.advanced])
        XCTAssertEqual(Tab.Group.allCases.map(\.rawValue), ["Remember", "Assistant", "Writing", "Sharing"])
        func pages(_ group: Tab.Group) -> [Tab] { Tab.allCases.filter { $0.group == group } }
        XCTAssertEqual(pages(.remember), [.recording, .dayMemory, .files, .email])
        XCTAssertEqual(pages(.assistant), [.ask, .personalContext, .daily])
        XCTAssertEqual(pages(.writing), [.writing, .dictation])
        XCTAssertEqual(pages(.sharing), [.agents, .devices])
        // Every page is listed exactly once.
        let listed = [.overview] + Tab.leadingPages + Tab.Group.allCases.flatMap(pages) + Tab.trailingPages
        XCTAssertEqual(listed, Tab.allCases)
        XCTAssertEqual(Set(Tab.allCases.map(\.displayName)).count, Tab.allCases.count)
    }

    /// Renames are display names only: raw values, which the CLI, deep links
    /// and the saved selection use, stay as they were.
    func testRenamedPagesKeepTheirIdentifiers() {
        typealias Tab = AppState.SettingsTab
        XCTAssertEqual(Tab.personalContext.displayName, "About you")
        XCTAssertEqual(Tab.agents.displayName, "AI agents")
        XCTAssertEqual(Tab.dayMemory.displayName, "Screen & activity")
        XCTAssertEqual(Tab.daily.displayName, "Daily review")
        XCTAssertEqual(Tab.privacy.displayName, "Privacy & permissions")
        XCTAssertEqual(Tab.writing.displayName, "Autocomplete")
        XCTAssertEqual(Tab.allCases.map(\.rawValue).sorted(), SettingCategory.allCases.map(\.rawValue).sorted())
        XCTAssertEqual(Tab(captureName: "personal context"), .personalContext)
        XCTAssertEqual(Tab(captureName: "about you"), .personalContext)
        XCTAssertEqual(Tab(captureName: "external agents"), .agents)
    }

    /// Search still finds a page's settings by the name the page had before.
    @MainActor
    func testSearchFindsSettingsByFormerPageNames() {
        XCTAssertTrue(SettingDescriptor.search("Personal Context", language: .english)
            .contains { $0.category == .personalContext })
        XCTAssertTrue(SettingDescriptor.search("About you", language: .english)
            .contains { $0.category == .personalContext })
        XCTAssertTrue(SettingDescriptor.search("External Agents", language: .english)
            .contains { $0.category == .agents })
        XCTAssertTrue(SettingDescriptor.search("AI agents", language: .english)
            .contains { $0.category == .agents })
        // Every setting search knows still belongs to a page in the list.
        XCTAssertTrue(SettingDescriptor.all.allSatisfy { AppState.SettingsTab.allCases.contains($0.category) })
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
