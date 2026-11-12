import Foundation

/// A page that a row of a Settings page opens in its place, with a way
/// back: Autocomplete's writing profile, skipped apps, usage and advanced
/// settings, and Dictation's writing profile and recent dictations.
enum SettingsSubpage: String, CaseIterable, Identifiable, Sendable {
    case autocompleteProfile, autocompleteExclusions, autocompleteUsage, autocompleteAdvanced
    case dictationProfile, dictationRecent

    var id: String { rawValue }

    /// The Settings page the row is on.
    var page: AppState.SettingsTab {
        switch self {
        case .autocompleteProfile, .autocompleteExclusions, .autocompleteUsage, .autocompleteAdvanced: .writing
        case .dictationProfile, .dictationRecent: .dictation
        }
    }

    var title: String {
        switch self {
        case .autocompleteProfile, .dictationProfile: "Writing profile"
        case .autocompleteExclusions: "Apps and sites to skip"
        case .autocompleteUsage: "Usage"
        case .autocompleteAdvanced: "Advanced"
        case .dictationRecent: "Recent dictations"
        }
    }

    /// The settings that are edited on this page, so settings search and
    /// deep links open it and land on them.
    var settingIDs: [String] {
        switch self {
        case .autocompleteProfile:
            ["settings.cotypingUserName", "settings.cotypingStyleNote", "settings.cotypingLanguages",
             "settings.cotypingUseLocalLearning"]
        case .autocompleteExclusions:
            ["settings.cotypingExcludedApps", "settings.cotypingExcludedDomains",
             "settings.cotypingSuggestInIntegratedTerminals"]
        case .autocompleteUsage:
            ["settings.autocompleteStatistics"]
        case .autocompleteAdvanced:
            ["settings.cotypingInProcessRuntime", "settings.cotypingChromiumEnhancedAccessibility"]
        case .dictationProfile:
            ["settings.dictationWritingProfile"]
        case .dictationRecent:
            []
        }
    }

    /// The page that holds a setting, when it is not on its Settings page
    /// itself. The writing profile's fields are Autocomplete's settings, so
    /// they open there.
    static func containing(settingID: String, on page: AppState.SettingsTab) -> SettingsSubpage? {
        allCases.first { $0.page == page && $0.settingIDs.contains(settingID) }
    }
}

/// How many apps and sites a comma-separated exclusion list names.
enum ExclusionRuleCount {
    static func count(_ lists: String...) -> Int {
        lists.reduce(0) { total, list in
            total + list.split(separator: ",")
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        }
    }
}
