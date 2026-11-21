import Foundation

enum SettingsSubpage: String, CaseIterable, Identifiable, Sendable {
    case autocompleteProfile, autocompleteExclusions, autocompleteUsage, autocompleteAdvanced
    case dictationProfile, dictationRecent

    var id: String { rawValue }

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

    static func containing(settingID: String, on page: AppState.SettingsTab) -> SettingsSubpage? {
        allCases.first { $0.page == page && $0.settingIDs.contains(settingID) }
    }
}

enum ExclusionRuleCount {
    static func count(_ lists: String...) -> Int {
        lists.reduce(0) { total, list in
            total + list.split(separator: ",")
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        }
    }
}
