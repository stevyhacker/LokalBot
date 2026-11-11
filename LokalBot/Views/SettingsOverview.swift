import AppKit
import SwiftUI

/// Settings → Overview, opened from the LokalBot row at the top of the list.
/// A status page: what needs the person, each with its own fix, then where
/// the data is, the keyboard shortcuts and the version. Features are turned
/// on and off on their own pages, beside what explains them.
struct SettingsOverview: View {
    @EnvironmentObject private var app: AppState
    let status: SettingsStatus
    @ObservedObject var personalModel: PersonalModelController
    @State private var libraryBytes: Int64?

    private var localized: (String) -> String { app.settings.appLanguage.catalog }

    var body: some View {
        Form {
            Section {
                headline
                ForEach(status.needs) { need in needRow(need) }
                if !status.modelsDownloading.isEmpty { downloadingRow }
                learnedRow
            }
            Section("Your data") {
                dataRow
                SettingsLibraryRow(bytes: libraryBytes, showsPath: false)
                modelsRow
            }
            shortcuts
        }
        .formStyle(.grouped)
        .frame(maxWidth: LBTokens.Metric.readingMaxWidth + 56)
        .frame(maxWidth: .infinity)
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("settings.overview")
        .task {
            personalModel.loadIfNeeded()
            libraryBytes = await SettingsLibrarySize.measure(root: app.storage.rootURL)
        }
    }

    // MARK: - What needs you

    private var headline: some View {
        let text = status.headline
        return HStack(spacing: 14) {
            Image(systemName: status.needsAttention ? "exclamationmark.triangle" : "checkmark")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(status.needsAttention ? LBTokens.Palette.attentionText : Brand.teal)
                .frame(width: 42, height: 42)
                .background((status.needsAttention ? LBTokens.Palette.attention : Brand.teal).opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: text.title.string(localized))
                    .font(AppFont.scaled(.title2).weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("settings.overview.headline")
                Text(verbatim: text.detail.string(localized))
                    .font(AppFont.scaled(.callout))
                    .settingsSecondary()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
    }

    private func needRow(_ need: SettingsStatus.Need) -> some View {
        let fix = fix(for: need)
        return HStack(spacing: 12) {
            IconTile(systemImage: icon(for: need), tint: LBTokens.Palette.attentionText, size: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: status.title(of: need).string(localized))
                Text(verbatim: status.detail(of: need).string(localized))
                    .font(.scaled(.callout))
                    .settingsSecondary()
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            SettingsFixButton(title: fix.title, action: fix.action,
                              identifier: "settings.overview.attention.\(identifier(for: need))")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.overview.need.\(identifier(for: need))")
    }

    private func identifier(for need: SettingsStatus.Need) -> String {
        switch need {
        case .permission(let permission, _): permission.rawValue
        case .download: "models"
        case .modelAttention(let role): "model.\(role.rawValue)"
        }
    }

    private func icon(for need: SettingsStatus.Need) -> String {
        switch need {
        case .permission(let permission, _): permission.icon
        case .download: "arrow.down.to.line"
        case .modelAttention: "exclamationmark.triangle"
        }
    }

    private func fix(for need: SettingsStatus.Need) -> (title: String, action: SettingsStatusLine.Action) {
        switch need {
        case .permission(let permission, _): (status.allowTitle(permission), .allow(permission))
        case .download: ("Download", .download)
        case .modelAttention: ("Review…", .open(.models, focus: nil))
        }
    }

    private var downloadingRow: some View {
        HStack(spacing: 12) {
            IconTile(systemImage: "arrow.down.to.line", tint: Brand.teal, size: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Downloading the models")
                Text(verbatim: status.modelsDownloading.map(\.name).joined(separator: ", "))
                    .font(.scaled(.callout))
                    .settingsSecondary()
            }
            Spacer(minLength: 8)
            if let fraction = status.downloadFraction {
                ProgressView(value: fraction).frame(width: 160).tint(Brand.tealFill)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.overview.downloading")
    }

    /// What LokalBot learned waits for a look, but stops nothing from working.
    @ViewBuilder private var learnedRow: some View {
        let learned = personalModel.suggestions.count
        if learned > 0 {
            HStack(spacing: 12) {
                IconTile(systemImage: AppState.SettingsTab.personalContext.icon, tint: Brand.teal, size: 28)
                    .accessibilityHidden(true)
                Text("\(learned) things LokalBot learned about you are waiting for review.")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                SettingsFixButton(title: "Review…", action: .open(.personalContext, focus: nil),
                                  identifier: "settings.overview.attention.learned")
            }
        }
    }

    // MARK: - Your data

    private var dataRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if status.everythingStaysHere {
                    Text("Everything stays on this Mac")
                    SettingsHelp("Audio, transcripts and screen text are never uploaded.")
                } else {
                    Text("Some things leave this Mac")
                    Text(verbatim: leaving)
                        .font(.scaled(.callout))
                        .foregroundStyle(LBTokens.Palette.attentionText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            SettingsFixButton(title: status.everythingStaysHere ? "Details…" : "Review…",
                              action: .open(.privacy, focus: nil), identifier: "settings.overview.privacy")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.overview.data")
    }

    /// Where things go: each AI server, then phones and tablets.
    private var leaving: String {
        var places = status.remoteHosts
        if status.sharesWithDevices { places.append(localized("Phones & tablets")) }
        return places.joined(separator: ", ")
    }

    private var modelsRow: some View {
        Button { SettingsStatusActions.perform(.open(.models, focus: nil), in: app) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Models")
                    if let line = status.lines(for: .models).first {
                        Text(verbatim: line.text.string(localized))
                            .font(.scaled(.callout))
                            .settingsSecondary()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.forward").font(.scaled(.caption)).settingsSecondary()
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.overview.models")
    }

    // MARK: - Shortcuts

    private var shortcuts: some View {
        let settings = app.settings
        let rows: [(LocalizedStringKey, String, Bool, AppState.SettingsTab?)] = [
            ("Ask anywhere", settings.quickRecallShortcut.displayLabel, settings.quickRecallEnabled, .ask),
            ("Selection actions", settings.selectionActionsShortcut.displayLabel, settings.selectionActionsEnabled, .ask),
            ("Dictation", settings.dictationShortcut.displayLabel, settings.dictationEnabled, .dictation),
            ("Accept a suggestion", localized(settings.cotypingAcceptKey.label), settings.cotypingEnabled, .writing),
            ("Command palette", "⌘K", true, nil),
        ]
        return Section {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                shortcutRow(row.0, keys: row.1, on: row.2, page: row.3)
            }
        } header: {
            Text("Keyboard shortcuts").accessibilityIdentifier("settings.overview.shortcuts")
        } footer: {
            Text(verbatim: "LokalBot " + AppUpdateManager.currentVersionString)
                .font(.scaled(.subheadline))
                .settingsSecondary()
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 10)
                .accessibilityIdentifier("settings.overview.version")
        }
    }

    /// A shortcut opens the page that sets it. One that is off says so.
    @ViewBuilder
    private func shortcutRow(_ title: LocalizedStringKey, keys: String, on: Bool, page: AppState.SettingsTab?) -> some View {
        let row = HStack(spacing: 10) {
            Text(title).foregroundStyle(on ? .primary : .secondary)
            Spacer(minLength: 8)
            if !on { Text("Off").font(.scaled(.callout)).settingsSecondary() }
            Text(verbatim: keys)
                .font(.scaled(.callout).monospaced())
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(LBTokens.Palette.groupFill, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(LBTokens.Palette.groupStroke))
                .opacity(on ? 1 : 0.55)
        }
        .contentShape(Rectangle())
        if let page {
            Button { SettingsStatusActions.perform(.open(page, focus: nil), in: app) } label: { row }
                .buttonStyle(.plain)
        } else {
            row
        }
    }
}

/// Where the library is and how much it holds, with a way to see it in
/// Finder. Overview and Privacy & permissions share it.
struct SettingsLibraryRow: View {
    @EnvironmentObject private var app: AppState
    /// Nil until the library has been measured.
    let bytes: Int64?
    /// Privacy & permissions names the folder; Overview says what is in it.
    let showsPath: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Library")
                Text(verbatim: detail)
                    .font(.scaled(.callout))
                    .settingsSecondary()
                    .lineLimit(showsPath ? 1 : nil)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([app.storage.rootURL])
            }
            .controlSize(.small)
            .accessibilityIdentifier("settings.library.showInFinder")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.library")
    }

    private var detail: String {
        let what = showsPath
            ? (app.storage.rootURL.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
            : app.settings.appLanguage.localized("Meetings, day memory, and the search index.")
        guard let bytes else { return what }
        return what + " · " + SettingsStatus.size(bytes)
    }
}
