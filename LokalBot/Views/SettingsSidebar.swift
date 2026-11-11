import AppKit
import SwiftUI

/// Measurements of the Settings window, whose content runs to the top edge.
enum SettingsChrome {
    /// The bar that holds back, forward and the page's name.
    static let topBarHeight: CGFloat = 50
    /// Room the traffic lights take above the search field.
    static let trafficLightsHeight: CGFloat = 38
}

/// The Settings window's list: search, the LokalBot row that opens Overview,
/// then every page in its group. Feature rows say "Off" or "Paused" at the
/// right, and the page where something is fixed carries a count.
struct SettingsSidebar: View {
    @EnvironmentObject private var app: AppState
    let status: SettingsStatus
    @Binding var query: String

    private var queryIsEmpty: Bool { query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Color.clear.frame(height: SettingsChrome.trafficLightsHeight).accessibilityHidden(true)
            searchField.padding(.horizontal, 12)
            List(selection: Binding(get: { queryIsEmpty ? Optional(app.settingsTab) : nil }, set: {
                if let page = $0 { app.selectSettingsTab(page); query = "" }
            })) {
                SettingsIdentityRow(status: status)
                    .tag(AppState.SettingsTab.overview)
                    .listRowSeparator(.hidden)
                ForEach(AppState.SettingsTab.leadingPages, id: \.self) { row($0) }
                // Headings are plain rows, like the main sidebar's: a List
                // Section reaches accessibility as a group with no name.
                ForEach(AppState.SettingsTab.Group.allCases, id: \.self) { group in
                    Text(LocalizedStringKey(group.rawValue))
                        .font(.scaled(.subheadline).bold())
                        .settingsSecondary()
                        .padding(.top, 8)
                        .accessibilityAddTraits(.isHeader)
                        .selectionDisabled(true)
                        .listRowSeparator(.hidden)
                        .accessibilityIdentifier("settings.group.\(group)")
                    ForEach(AppState.SettingsTab.allCases.filter { $0.group == group }, id: \.self) { row($0) }
                }
                // The gap above the last page is padding on its row. An empty
                // spacer row was a list cell with nothing to read, which
                // VoiceOver stopped on and the accessibility audit flagged.
                ForEach(AppState.SettingsTab.trailingPages, id: \.self) { page in
                    row(page).padding(.top, page == AppState.SettingsTab.trailingPages.first ? 14 : 0)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .tint(Brand.tealFill)
            .accessibilityLabel("Settings categories")
            .accessibilityIdentifier("settings.categories")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings navigation")
    }

    private func row(_ page: AppState.SettingsTab) -> some View {
        SettingsCategoryRow(page: page, state: status.rowState(page), badge: status.badge(page))
            .padding(.vertical, 3)
            .tag(page)
            .listRowSeparator(.hidden)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .settingsSecondary()
                .accessibilityHidden(true)
            TextField("Search settings…", text: $query)
                .textFieldStyle(.plain)
                .font(AppFont.scaled(.body))
                .accessibilityIdentifier("settings.search")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .settingsSecondary()
                .accessibilityLabel("Clear settings search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .settingsPanel()
    }
}

/// The row at the top of the list, where System Settings puts the account:
/// the app, and under it how many things need the person.
private struct SettingsIdentityRow: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.backgroundProminence) private var prominence
    let status: SettingsStatus

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "LokalBot")
                    .font(.scaled(.body).weight(.semibold))
                Text(verbatim: status.summary.string(app.settings.appLanguage.catalog))
                    .font(.scaled(.callout))
                    .foregroundStyle(summaryStyle)
                    .lineLimit(2)
                    .accessibilityIdentifier("settings.identity.summary")
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .accessibilityIdentifier("settings.identity")
    }

    private var summaryStyle: AnyShapeStyle {
        if prominence == .increased { return AnyShapeStyle(.primary) }
        return status.needsAttention ? AnyShapeStyle(LBTokens.Palette.attentionText) : AnyShapeStyle(.secondary)
    }
}

/// Category glyphs carry the accent like Agent's starters. A selected row on
/// the prominent accent highlight falls back to the row's own foreground so
/// nothing disappears into a teal fill.
private struct SettingsCategoryRow: View {
    @Environment(\.backgroundProminence) private var prominence
    let page: AppState.SettingsTab
    let state: SettingsStatus.RowState
    let badge: Int

    private var selected: Bool { prominence == .increased }

    var body: some View {
        HStack(spacing: 6) {
            Label {
                Text(LocalizedStringKey(page.displayName))
            } icon: {
                Image(systemName: page.icon)
                    .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(Brand.teal))
            }
            .font(.scaled(.body))
            Spacer(minLength: 4)
            if badge > 0 {
                Text(badge, format: .number)
                    .font(.scaled(.caption).weight(.bold).monospacedDigit())
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                    .padding(.horizontal, 6)
                    .frame(minWidth: 18, minHeight: 17)
                    .background(LBTokens.Palette.attentionText, in: Capsule())
                    .accessibilityLabel(badgeLabel)
                    .accessibilityIdentifier("settings.category.\(page.rawValue).badge")
            } else if state == .paused {
                Text("Paused")
                    .font(.scaled(.subheadline).weight(.semibold))
                    .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(LBTokens.Palette.attentionText))
                    .accessibilityIdentifier("settings.category.\(page.rawValue).state")
            } else if state == .off {
                Text("Off")
                    .font(.scaled(.subheadline))
                    .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .accessibilityIdentifier("settings.category.\(page.rawValue).state")
            }
        }
    }

    private var badgeLabel: Text {
        badge == 1 ? Text("1 thing needs you") : Text("\(badge) things need you")
    }
}
