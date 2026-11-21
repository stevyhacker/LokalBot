import AppKit
import SwiftUI

extension SettingsStatus.Input {
    @MainActor
    init(app: AppState, permissions: PermissionManager, downloadMinutesLeft: Int? = nil) {
        let settings = app.settings
        let snapshot = app.modelRoles.snapshot
        let plan = OnboardingDownloadPlan(
            settings: settings, statuses: snapshot.statuses, includeAutocomplete: true,
            started: true, readyBefore: [], availableBytes: snapshot.readiness.availableBytes)
        var models = plan.models.map { model in
            SettingsStatus.Model(role: model.role, name: model.name, bytes: model.bytes,
                                 downloads: model.downloads, status: snapshot[model.role])
        }
        if !models.contains(where: { $0.role == .autocomplete }) {
            models.append(.init(role: .autocomplete, name: settings.cotypingModelDisplayName, bytes: nil,
                                downloads: false, status: snapshot[.autocomplete]))
        }
        let calendar: SettingsStatus.CalendarAccess
        switch app.calendar.authorizationStatus {
        case .fullAccess: calendar = .allowed
        case .notDetermined: calendar = .notAsked
        case .restricted, .denied, .writeOnly: calendar = .refused
        }
        self.init(settings: settings,
                  granted: permissions.granted,
                  grantedAtLaunch: permissions.grantedAtLaunch,
                  calendar: calendar,
                  models: models,
                  freeBytes: snapshot.readiness.availableBytes,
                  downloadMinutesLeft: downloadMinutesLeft,
                  failedChecks: ModelRole.allCases.filter { app.modelChecks.results[$0]?.failure != nil },
                  emailConnected: !app.email.accounts.isEmpty,
                  agentKinds: app.agentReadAccess.granted.count,
                  agentsCanChangeSettings: app.settingsControl.isEnabled,
                  pairedDevices: app.companion.devices.count)
    }
}

struct SettingsStatusObserver: View {
    @ObservedObject var app: AppState
    @ObservedObject var permissions: PermissionManager
    @ObservedObject var modelRoles: ModelRoles
    @ObservedObject var access: AgentReadAccess
    @ObservedObject var settingsControl: SettingsControlAccessManager
    @ObservedObject var email: EmailController
    @ObservedObject var companion: CompanionHost
    @ObservedObject var calendar: EventKitCalendarEventProvider
    @ObservedObject var checks: ModelCheckController
    @Binding var status: SettingsStatus
    @State private var estimator = DownloadTimeEstimator()
    @State private var minutesLeft: Int?

    var body: some View {
        let current = SettingsStatus(.init(app: app, permissions: permissions, downloadMinutesLeft: minutesLeft))
        Color.clear
            .accessibilityHidden(true)
            .onChange(of: current, initial: true) { _, latest in
                if status != latest { status = latest }
            }
            .onChange(of: current.runningDownload?.arrived) { _, _ in
                guard let running = current.runningDownload else {
                    estimator.reset()
                    minutesLeft = nil
                    return
                }
                estimator.record(downloadedBytes: running.arrived, at: Date())
                let left = estimator.minutesLeft(totalBytes: running.total)
                if left != minutesLeft { minutesLeft = left }
            }
    }
}

@MainActor
enum SettingsStatusActions {
    static func perform(_ action: SettingsStatusLine.Action, in app: AppState, from frame: CGRect? = nil) {
        switch action {
        case .allow(let permission):
            allow(permission, in: app, from: frame)
        case .download:
            app.modelRoles.startCoreModelDownloads(includeAutocomplete: app.settings.cotypingEnabled)
        case .relaunch:
            app.settingsStore.flush()
            PermissionManager.relaunch()
        case .open(let page, let focus):
            app.selectSettingsTab(page)
            if let focus { app.focusedSettingID = focus }
        }
    }

    static func allow(_ permission: SettingsPermission, in app: AppState, from frame: CGRect? = nil) {
        if let appPermission = permission.appPermission {
            PermissionGuidanceController.shared.requestAccess(
                for: appPermission, sourceFrameInScreen: frame.flatMap { $0 == .zero ? nil : $0 })
            return
        }
        if app.calendar.authorizationStatus == .notDetermined {
            app.calendar.requestAccess { _ in }
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct SettingsFixButton: View {
    @EnvironmentObject private var app: AppState
    let title: String
    let action: SettingsStatusLine.Action
    var link = false
    var identifier: String?
    @State private var frame = CGRect.zero

    var body: some View {
        Group {
            if link {
                button.buttonStyle(.workspaceLink)
            } else {
                button.buttonStyle(.bordered)
            }
        }
        .controlSize(.small)
        .background(PermissionScreenFrameReader(frameInScreen: $frame))
        .accessibilityIdentifier(identifier ?? "")
    }

    private var button: some View {
        Button { SettingsStatusActions.perform(action, in: app, from: frame) } label: {
            Text(LocalizedStringKey(title))
        }
    }
}

struct SettingsPageHeader<Accessory: View>: View {
    @EnvironmentObject private var app: AppState
    let page: AppState.SettingsTab
    let status: SettingsStatus
    var tryIt: (() -> Void)?
    var isOn: Binding<Bool>?
    var switchLabel: String?
    var switchSettingID: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        let lines = status.lines(for: page)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                IconTile(systemImage: page.icon, tint: Brand.teal, size: 38)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(page.displayName))
                        .font(AppFont.scaled(.title2).weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                    Text(verbatim: summary)
                        .font(AppFont.scaled(.callout))
                        .settingsSecondary()
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                accessory
                if let tryIt {
                    Button("Try it…", action: tryIt)
                        .accessibilityIdentifier("settings.header.\(page.rawValue).tryIt")
                }
                if let isOn {
                    Toggle(isOn: isOn) { Text(LocalizedStringKey(switchLabel ?? page.displayName)) }
                        .labelsHidden()
                        .toggleStyle(LBAccentSwitchStyle())
                        .accessibilityLabel(Text(LocalizedStringKey(switchLabel ?? page.displayName)))
                        .accessibilityIdentifier(switchSettingID ?? "settings.header.\(page.rawValue).switch")
                        .settingTarget(switchSettingID ?? "", selected: app.focusedSettingID)
                }
            }
            .padding(.vertical, 4)
            ForEach(lines) { line in
                Divider().padding(.top, 8).padding(.bottom, 2)
                SettingsStatusLineRow(line: line, page: page)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.header.\(page.rawValue)")
    }

    private var summary: String {
        let localized = app.settings.appLanguage.catalog
        return page == .dictation
            ? String(format: localized(page.summary), app.settings.dictationShortcut.displayLabel)
            : localized(page.summary)
    }
}

extension SettingsPageHeader where Accessory == EmptyView {
    init(page: AppState.SettingsTab, status: SettingsStatus, tryIt: (() -> Void)? = nil,
         isOn: Binding<Bool>? = nil, switchLabel: String? = nil, switchSettingID: String? = nil) {
        self.init(page: page, status: status, tryIt: tryIt, isOn: isOn, switchLabel: switchLabel,
                  switchSettingID: switchSettingID) { EmptyView() }
    }
}

extension View {
    func settingsPageHeaderCard() -> some View {
        padding(.horizontal, 14).padding(.vertical, 10).settingsPanel()
    }
}

struct SettingsStatusLineRow: View {
    @EnvironmentObject private var app: AppState
    let line: SettingsStatusLine
    let page: AppState.SettingsTab

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            sign
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(verbatim: line.text.string(app.settings.appLanguage.catalog))
                .font(AppFont.scaled(.callout))
                .foregroundStyle(line.tone == .quiet ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if case .progress(let fraction) = line.tone {
                if let fraction {
                    ProgressView(value: fraction).frame(width: 140).tint(Brand.tealFill)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            if let action = line.action, let title = line.buttonTitle {
                SettingsFixButton(title: title, action: action, link: line.isLink,
                                  identifier: "settings.status.\(page.rawValue).\(line.id).action")
            }
        }
        .frame(minHeight: 26)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.status.\(page.rawValue).\(line.id)")
    }

    @ViewBuilder private var sign: some View {
        switch line.tone {
        case .need:
            Image(systemName: "exclamationmark.triangle").foregroundStyle(LBTokens.Palette.attentionText)
        case .online:
            Image(systemName: "globe").foregroundStyle(LBTokens.Palette.attentionText)
        case .ok:
            StatusDot(color: LBTokens.Palette.success)
        case .quiet:
            StatusDot(color: Color.secondary.opacity(0.5))
        case .progress:
            Image(systemName: "arrow.down.circle").foregroundStyle(Brand.teal)
        }
    }
}

enum SettingsLibrarySize {
    static func measure(root: URL) async -> Int64 {
        await Task.detached(priority: .utility) {
            let models = root.appendingPathComponent("models", isDirectory: true).standardizedFileURL.path
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isDirectoryKey],
                options: []) else { return Int64(0) }
            var total: Int64 = 0
            while let url = enumerator.nextObject() as? URL {
                if Task.isCancelled { break }
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isDirectoryKey])
                else { continue }
                if values.isDirectory == true {
                    if url.standardizedFileURL.path == models { enumerator.skipDescendants() }
                    continue
                }
                if values.isRegularFile == true { total += Int64(values.fileSize ?? 0) }
            }
            return total
        }.value
    }
}
