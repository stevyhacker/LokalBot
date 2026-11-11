import Foundation

/// A permission row on Privacy & permissions: macOS's four privacy grants
/// and Calendar, in the order the page lists them.
enum SettingsPermission: String, CaseIterable, Identifiable, Sendable {
    case microphone, accessibility, inputMonitoring, screenRecording, calendar

    var id: Self { self }

    /// Nil for Calendar, which EventKit grants.
    var appPermission: AppPermission? {
        switch self {
        case .microphone: .microphone
        case .accessibility: .accessibility
        case .inputMonitoring: .inputMonitoring
        case .screenRecording: .screenRecording
        case .calendar: nil
        }
    }

    var title: String { appPermission?.title ?? "Calendar" }

    var icon: String {
        switch self {
        case .microphone: "mic"
        case .accessibility: "accessibility"
        case .inputMonitoring: "keyboard"
        case .screenRecording: "rectangle.dashed.badge.record"
        case .calendar: "calendar"
        }
    }

    /// The features that can use it, whether or not they are on now.
    var usedBy: String {
        switch self {
        case .microphone: "Meetings and Dictation"
        case .accessibility: "Autocomplete, window titles, selection actions, and pasting dictated text"
        case .inputMonitoring: "The Dictation and Autocomplete shortcuts"
        case .screenRecording: "Screenshots in Screen & activity, and Dictation when it reads a whole window"
        case .calendar: "Confirms meetings and names them after your calendar events"
        }
    }

    /// What Overview asks for.
    var allowTitle: String {
        switch self {
        case .microphone: "Allow the microphone"
        case .accessibility: "Allow Accessibility"
        case .inputMonitoring: "Allow Input Monitoring"
        case .screenRecording: "Allow Screen Recording"
        case .calendar: "Allow Calendar access"
        }
    }

    /// A grant made while LokalBot runs reaches these only at the next launch.
    var needsRelaunchAfterGrant: Bool { appPermission?.needsRelaunchAfterGrant ?? false }
}

/// Interface text a model type puts together: a catalog key and what fills
/// its placeholders. The view looks the key up in the app's language.
struct SettingsText: Equatable, Sendable {
    enum Argument: Equatable, Sendable {
        /// Names, hosts and sizes, shown as they are.
        case verbatim(String)
        /// A catalog key, such as a permission's title.
        case key(String)
        /// Catalog keys joined into one list.
        case list([String])
        case count(Int)
    }

    var key: String
    var arguments: [Argument] = []

    init(_ key: String, _ arguments: Argument...) {
        self.key = key
        self.arguments = arguments
    }

    func string(_ localized: (String) -> String) -> String {
        let values = arguments.map { argument -> CVarArg in
            switch argument {
            case .verbatim(let text): return text
            case .key(let key): return localized(key)
            case .list(let keys): return keys.map(localized).joined(separator: ", ")
            case .count(let count): return count
            }
        }
        return values.isEmpty ? localized(key) : String(format: localized(key), arguments: values)
    }
}

/// One line under a Settings page's header: whether the feature works, and
/// when it does not, the one control that fixes it.
struct SettingsStatusLine: Equatable, Identifiable, Sendable {
    enum Tone: Equatable, Sendable {
        /// Something the person has to do: amber, with a warning sign.
        case need
        /// Working: a green dot.
        case ok
        /// Off, or waiting on something that is already under way: gray.
        case quiet
        /// Something leaves this Mac: amber, with a globe.
        case online
        /// Under way, with how far along it is when that is known.
        case progress(Double?)
    }

    enum Action: Equatable, Sendable {
        /// Ask for the permission, the same way Privacy & permissions does.
        case allow(SettingsPermission)
        /// Start downloading the models that are missing.
        case download
        case relaunch
        /// Open another Settings page, on a setting when one is named.
        case open(AppState.SettingsTab, focus: String?)
    }

    var id: String
    var tone: Tone
    var text: SettingsText
    var action: Action?
    /// The action's button title, for an `open` whose title is not "Change…".
    var actionTitle: String?

    var buttonTitle: String? {
        if let actionTitle { return actionTitle }
        switch action {
        case .allow: return "Allow…"
        case .download: return "Download"
        case .relaunch: return "Relaunch"
        case .open: return "Change…"
        case nil: return nil
        }
    }

    /// Buttons fix something; links only take you somewhere.
    var isLink: Bool {
        if case .open = action { return true }
        return false
    }
}

/// What the Settings window says about the state of each feature: the
/// "Off" and "Paused" marks and count badges in its list, what needs the
/// person on Overview, each permission's row on Privacy & permissions, and
/// the status lines under every page's header. Derived from real state and
/// nothing else, so each of those places says the same thing.
struct SettingsStatus: Equatable {
    enum Access: Equatable, Sendable {
        case allowed
        /// A feature that is on uses it, and it is not granted.
        case missing
        /// Not granted, and nothing that is on uses it.
        case notNeeded
    }

    enum RowState: Equatable, Sendable {
        case normal
        case off
        /// On, but blocked by a missing permission or model.
        case paused
    }

    enum CalendarAccess: Equatable, Sendable {
        case allowed
        /// macOS has not asked yet, so LokalBot can.
        case notAsked
        /// Refused: only System Settings can turn it on.
        case refused
    }

    /// A feature that uses a permission, named in "Needed for: …".
    enum Feature: String, Equatable, Sendable {
        case meetings = "Meetings"
        case dictation = "Dictation"
        case autocomplete = "Autocomplete"
        case windowTitles = "Window titles"
        case screenText = "Screen & activity"
        case selectionActions = "Selection actions"
        case windowHandoff = "Hand off this window"
    }

    /// One of the three models, as far as Settings needs to describe it.
    struct Model: Equatable, Sendable {
        var role: ModelRole
        var name: String
        /// What its download weighs, when one is needed and its size is known.
        var bytes: Int64?
        /// False for a server or Apple Intelligence: nothing downloads.
        var downloads: Bool
        var status: ModelRoleStatus

        /// "Gemma 4 E2B (3.85 GB)", or the name alone when the size is unknown.
        var nameAndSize: String {
            guard downloads, let bytes, bytes > 0 else { return name }
            return "\(name) (\(SettingsStatus.size(bytes)))"
        }
    }

    struct Input: Equatable {
        var settings = AppSettings()
        /// The real grants. A permission with no entry has not been read
        /// yet and counts as granted, so no warning flashes on open.
        var granted: [AppPermission: Bool] = [:]
        /// What was granted when this launch began.
        var grantedAtLaunch: [AppPermission: Bool] = [:]
        var calendar: CalendarAccess = .allowed
        var models: [Model] = []
        /// Free space on the volume that holds the models.
        var freeBytes: Int64?
        var emailConnected = false
        /// The kinds of data external agents may read.
        var agentKinds = 0
        var agentsCanChangeSettings = false
        var pairedDevices = 0
    }

    /// Something only the person can fix, listed on Overview.
    enum Need: Equatable, Identifiable, Sendable {
        case permission(SettingsPermission, features: [Feature])
        /// Models that have to be downloaded, and what they weigh together.
        case download(roles: [ModelRole], bytes: Int64?)
        /// A model that stopped or is not set up.
        case modelAttention(ModelRole)

        var id: String {
            switch self {
            case .permission(let permission, _): "permission.\(permission.rawValue)"
            case .download: "models.download"
            case .modelAttention(let role): "models.attention.\(role.rawValue)"
            }
        }

        /// The page where it is fixed, which carries the count badge.
        var page: AppState.SettingsTab {
            switch self {
            case .permission: .privacy
            case .download, .modelAttention: .models
            }
        }
    }

    let input: Input

    init(_ input: Input) {
        self.input = input
    }

    private var settings: AppSettings { input.settings }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - Permissions

    private func granted(_ permission: AppPermission) -> Bool {
        input.granted[permission] ?? true
    }

    private func isGranted(_ permission: SettingsPermission) -> Bool {
        if let app = permission.appPermission { return granted(app) }
        return input.calendar == .allowed
    }

    private var dictationPastes: Bool {
        settings.dictationOutputMode == .pasteIntoFocusedApp || settings.dictationUseVisibleContext
    }

    private var dictationReadsWindow: Bool {
        settings.dictationIntent == .compose && settings.dictationUseScreenContext
    }

    /// The features that are on and use the permission now. Autocomplete
    /// reads the focused window only when Screen Recording is already
    /// granted and never asks for it, so it is not listed there.
    func features(using permission: SettingsPermission) -> [Feature] {
        var features: [Feature] = []
        switch permission {
        case .microphone:
            features.append(.meetings)
            if settings.dictationEnabled { features.append(.dictation) }
        case .accessibility:
            if settings.cotypingEnabled { features.append(.autocomplete) }
            if settings.trackingEnabled { features.append(.windowTitles) }
            if settings.effectiveScreenContextCaptureMode.capturesText { features.append(.screenText) }
            if settings.dictationEnabled, dictationPastes { features.append(.dictation) }
            if settings.selectionActionsEnabled { features.append(.selectionActions) }
            if settings.windowHandoffEnabled { features.append(.windowHandoff) }
        case .inputMonitoring:
            if settings.dictationEnabled { features.append(.dictation) }
            if settings.cotypingEnabled { features.append(.autocomplete) }
        case .screenRecording:
            if settings.effectiveScreenContextCaptureMode.capturesPixels { features.append(.screenText) }
            if settings.dictationEnabled, dictationReadsWindow { features.append(.dictation) }
        case .calendar:
            if settings.calendarDetectionEnabled { features.append(.meetings) }
        }
        return features
    }

    func access(_ permission: SettingsPermission) -> Access {
        if isGranted(permission) { return .allowed }
        return features(using: permission).isEmpty ? .notNeeded : .missing
    }

    /// Needed by something that is on, and not granted.
    var missingPermissions: [SettingsPermission] {
        SettingsPermission.allCases.filter { access($0) == .missing }
    }

    /// Granted since this launch began, and only working after the next one.
    var permissionsAwaitingRelaunch: [SettingsPermission] {
        SettingsPermission.allCases.filter { permission in
            guard permission.needsRelaunchAfterGrant, let app = permission.appPermission else { return false }
            return granted(app) && input.grantedAtLaunch[app] == false
        }
    }

    // MARK: - Models

    /// Transcribe and Think always; Autocomplete's model only while
    /// Autocomplete is on.
    private var requiredModels: [Model] {
        input.models.filter { $0.role != .autocomplete || settings.cotypingEnabled }
    }

    func model(_ role: ModelRole) -> Model? {
        input.models.first { $0.role == role }
    }

    var modelsToDownload: [Model] {
        requiredModels.filter { $0.downloads && $0.status == .unavailable }
    }

    var modelsNeedingAttention: [Model] {
        requiredModels.filter { model in
            if case .needsAttention = model.status { return true }
            return !model.downloads && model.status == .unavailable
        }
    }

    var modelsDownloading: [Model] {
        input.models.filter { $0.status.isWorking }
    }

    /// 0…1 across the models that are downloading, when their sizes and
    /// progress are known.
    var downloadFraction: Double? {
        let working = modelsDownloading
        guard !working.isEmpty else { return nil }
        var total: Int64 = 0
        var arrived: Double = 0
        for model in working {
            guard let bytes = model.bytes, bytes > 0, let progress = model.status.progress else { return nil }
            total += bytes
            arrived += Double(bytes) * min(1, max(0, progress))
        }
        return total > 0 ? arrived / Double(total) : nil
    }

    private static func totalBytes(_ models: [Model]) -> Int64? {
        guard !models.contains(where: { $0.bytes == nil }) else { return nil }
        return models.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) }
    }

    // MARK: - What leaves this Mac

    /// Every server the AI features send to, each named once.
    var remoteHosts: [String] { settings.remoteAIHosts }

    var sharesWithDevices: Bool { settings.companionSharingEnabled }

    /// True while no AI server is in use and nothing is shared with phones.
    var everythingStaysHere: Bool { remoteHosts.isEmpty && !sharesWithDevices }

    // MARK: - Overview

    var needs: [Need] {
        var needs = missingPermissions.map { Need.permission($0, features: features(using: $0)) }
        let downloads = modelsToDownload
        if !downloads.isEmpty {
            needs.append(.download(roles: downloads.map(\.role), bytes: Self.totalBytes(downloads)))
        }
        needs += modelsNeedingAttention.map { .modelAttention($0.role) }
        return needs
    }

    /// The second line of the LokalBot row at the top of the list.
    var summary: SettingsText {
        let count = needs.count
        if count == 1 { return SettingsText("1 thing needs you") }
        if count > 1 { return SettingsText("%lld things need you", .count(count)) }
        if !modelsDownloading.isEmpty { return SettingsText("Downloading models…") }
        return SettingsText("Everything is working")
    }

    var needsAttention: Bool { !needs.isEmpty }

    /// Overview's headline, and the line under it.
    var headline: (title: SettingsText, detail: SettingsText) {
        if needsAttention {
            return (summary, SettingsText("Until then, parts of LokalBot can’t run."))
        }
        if !modelsDownloading.isEmpty {
            return (SettingsText("Almost ready"), SettingsText("The models are downloading. Everything else is set up."))
        }
        if !remoteHosts.isEmpty {
            return (summary, SettingsText("Some AI runs online at %@. Everything else stays on this Mac.",
                                          .verbatim(remoteHosts.joined(separator: ", "))))
        }
        return (summary, SettingsText(sharesWithDevices
            ? "Nothing needs you." : "Nothing needs you, and everything stays on this Mac."))
    }

    func title(of need: Need) -> SettingsText {
        switch need {
        case .permission(let permission, _): SettingsText(permission.allowTitle)
        case .download: SettingsText("Download the models")
        case .modelAttention: SettingsText("A model needs attention")
        }
    }

    func detail(of need: Need) -> SettingsText {
        switch need {
        case .permission(_, let features):
            return SettingsText("Needed for: %@", .list(features.map(\.rawValue)))
        case .download(let roles, let bytes):
            let waiting = roles.contains(.transcribe) || roles.contains(.think)
                ? "New meetings wait to be transcribed until then." : "Autocomplete waits until then."
            guard let bytes, bytes > 0 else { return SettingsText(waiting) }
            return SettingsText("%@ · %@", .verbatim(Self.size(bytes)), .key(waiting))
        case .modelAttention(let role):
            let name = model(role)?.name ?? ""
            return SettingsText("%@ can’t be used yet.", .verbatim(name))
        }
    }

    // MARK: - The list

    /// "Off" or "Paused" at the right of a feature's row.
    func rowState(_ page: AppState.SettingsTab) -> RowState {
        switch page {
        case .overview, .general, .models, .privacy, .ask, .personalContext, .daily, .advanced:
            return .normal
        case .recording:
            return access(.microphone) == .missing ? .paused : .normal
        case .dayMemory:
            guard settings.trackingEnabled else { return .off }
            let mode = settings.effectiveScreenContextCaptureMode
            let blocked = (mode.capturesText && access(.accessibility) == .missing)
                || (mode.capturesPixels && access(.screenRecording) == .missing)
            return blocked ? .paused : .normal
        case .files:
            return settings.fileSearchEnabled ? .normal : .off
        case .email:
            return input.emailConnected ? .normal : .off
        case .writing:
            guard settings.cotypingEnabled else { return .off }
            let blocked = access(.accessibility) == .missing || access(.inputMonitoring) == .missing
                || model(.autocomplete).map { $0.status != .ready } ?? false
            return blocked ? .paused : .normal
        case .dictation:
            guard settings.dictationEnabled else { return .off }
            let blocked = SettingsPermission.allCases.contains { permission in
                features(using: permission).contains(.dictation) && access(permission) == .missing
            } || model(.transcribe).map { $0.status != .ready } ?? false
            return blocked ? .paused : .normal
        case .agents:
            return input.agentKinds > 0 || input.agentsCanChangeSettings ? .normal : .off
        case .devices:
            return settings.companionSharingEnabled ? .normal : .off
        }
    }

    /// How many things need the person on the page where they are fixed.
    func badge(_ page: AppState.SettingsTab) -> Int {
        needs.filter { $0.page == page }.count
    }

    // MARK: - Page headers

    /// The status lines under a page's header, most pressing first.
    func lines(for page: AppState.SettingsTab) -> [SettingsStatusLine] {
        switch page {
        case .privacy: privacyLines
        case .models: modelLines
        case .writing: autocompleteLines
        case .dictation: dictationLines
        case .recording: meetingLines
        case .dayMemory: screenLines
        case .files: settings.fileSearchEnabled ? [] : [offLine()]
        case .email: input.emailConnected ? [] : [offLine("Not connected")]
        case .agents: rowState(.agents) == .off ? [offLine()] : []
        case .devices: settings.companionSharingEnabled ? [] : [offLine()]
        case .overview, .general, .ask, .personalContext, .daily, .advanced: []
        }
    }

    private func offLine(_ key: String = "Off") -> SettingsStatusLine {
        SettingsStatusLine(id: "off", tone: .quiet, text: SettingsText(key))
    }

    /// macOS asks for Calendar once. After a refusal only System Settings
    /// can turn it on, and the button says so.
    func allowTitle(_ permission: SettingsPermission) -> String {
        permission == .calendar && input.calendar == .refused ? "Open System Settings…" : "Allow…"
    }

    private func allowLine(_ permission: SettingsPermission, _ key: String) -> SettingsStatusLine {
        SettingsStatusLine(id: "allow.\(permission.rawValue)", tone: .need, text: SettingsText(key),
                           action: .allow(permission), actionTitle: allowTitle(permission))
    }

    /// A grant that waits for the next launch, for the pages that use it.
    private func relaunchLines(_ permissions: [SettingsPermission]) -> [SettingsStatusLine] {
        permissionsAwaitingRelaunch.filter(permissions.contains).map { permission in
            SettingsStatusLine(id: "relaunch.\(permission.rawValue)", tone: .need,
                               text: SettingsText("%@ starts working after LokalBot reopens.", .key(permission.title)),
                               action: .relaunch)
        }
    }

    private var privacyLines: [SettingsStatusLine] {
        let missing = missingPermissions.count
        if missing == 1 {
            return [SettingsStatusLine(id: "permissions", tone: .need,
                                       text: SettingsText("1 permission is off, so a feature is paused."))]
        }
        if missing > 1 {
            return [SettingsStatusLine(id: "permissions", tone: .need,
                                       text: SettingsText("%lld permissions are off, so some features are paused.",
                                                          .count(missing)))]
        }
        if !everythingStaysHere {
            return [SettingsStatusLine(id: "leaves", tone: .online,
                                       text: SettingsText("Permissions are set. See below for what leaves this Mac."))]
        }
        return [SettingsStatusLine(id: "set", tone: .ok, text: SettingsText("All set. Nothing leaves this Mac."))]
    }

    private var modelLines: [SettingsStatusLine] {
        var lines: [SettingsStatusLine] = []
        let downloads = modelsToDownload
        if !downloads.isEmpty {
            let text: SettingsText
            if let bytes = Self.totalBytes(downloads), bytes > 0, let free = input.freeBytes {
                text = SettingsText("Not downloaded yet. They need %@, and this Mac has %@ free.",
                                    .verbatim(Self.size(bytes)), .verbatim(Self.size(free)))
            } else {
                text = SettingsText("%@ isn’t downloaded yet.",
                                    .verbatim(downloads.map(\.nameAndSize).joined(separator: ", ")))
            }
            lines.append(SettingsStatusLine(id: "download", tone: .need, text: text, action: .download))
        }
        lines += modelsNeedingAttention.map { model in
            SettingsStatusLine(id: "attention.\(model.role.rawValue)", tone: .need,
                               text: SettingsText("%@ can’t be used yet.", .verbatim(model.name)))
        }
        let working = modelsDownloading
        if !working.isEmpty {
            lines.append(SettingsStatusLine(
                id: "downloading", tone: .progress(downloadFraction),
                text: SettingsText("%@ is downloading.", .verbatim(working.map(\.name).joined(separator: ", ")))))
        }
        guard lines.isEmpty else { return lines }
        if remoteHosts.isEmpty {
            return [SettingsStatusLine(id: "ready", tone: .ok,
                                       text: SettingsText("All set. Every model runs on this Mac."))]
        }
        return [SettingsStatusLine(id: "ready", tone: .online,
                                   text: SettingsText("All set. Some AI runs online at %@.",
                                                      .verbatim(remoteHosts.joined(separator: ", "))))]
    }

    /// Whether the model is missing, on its way, stopped or ready.
    private func modelLine(_ role: ModelRole, focus: String) -> SettingsStatusLine? {
        guard let model = model(role) else { return nil }
        switch model.status {
        case .ready:
            return nil
        case .downloading, .preparing:
            return SettingsStatusLine(id: "model.downloading", tone: .progress(model.status.progress),
                                      text: SettingsText("%@ is downloading.", .verbatim(model.name)))
        case .unavailable where model.downloads:
            return SettingsStatusLine(id: "model.download", tone: .need,
                                      text: SettingsText("%@ isn’t downloaded yet.", .verbatim(model.nameAndSize)),
                                      action: .download)
        case .unavailable, .needsAttention:
            return SettingsStatusLine(id: "model.attention", tone: .need,
                                      text: SettingsText("%@ can’t be used yet.", .verbatim(model.name)),
                                      action: .open(.models, focus: focus), actionTitle: "Review…")
        }
    }

    private var autocompleteLines: [SettingsStatusLine] {
        guard settings.cotypingEnabled else {
            return [SettingsStatusLine(id: "off", tone: .quiet,
                                       text: SettingsText("Off. No suggestions appear in other apps."))]
        }
        var lines: [SettingsStatusLine] = []
        if access(.accessibility) == .missing {
            lines.append(allowLine(.accessibility,
                                   "Paused until you allow Accessibility, so it can see where you type."))
        }
        if access(.inputMonitoring) == .missing {
            lines.append(allowLine(.inputMonitoring,
                                   "Paused until you allow Input Monitoring, so it can tell when you accept a suggestion."))
        }
        lines += relaunchLines([.accessibility, .inputMonitoring])
        if let line = modelLine(.autocomplete, focus: "settings.cotypingBackend") { lines.append(line) }
        if let host = settings.cotypingRemoteHost {
            lines.append(SettingsStatusLine(id: "online", tone: .online,
                                            text: SettingsText("What you type is sent to %@, where its model runs.",
                                                               .verbatim(host)),
                                            action: .open(.models, focus: "settings.cotypingBackend")))
        } else if lines.isEmpty, let model = model(.autocomplete) {
            lines.append(SettingsStatusLine(id: "ready", tone: .ok,
                                            text: SettingsText("Ready · %@, on this Mac", .verbatim(model.name)),
                                            action: .open(.models, focus: "settings.cotypingBackend")))
        }
        return lines
    }

    private var dictationLines: [SettingsStatusLine] {
        guard settings.dictationEnabled else {
            return [SettingsStatusLine(id: "off", tone: .quiet,
                                       text: SettingsText("Off. The shortcut does nothing until you turn it on."))]
        }
        var lines: [SettingsStatusLine] = []
        if access(.microphone) == .missing {
            lines.append(allowLine(.microphone, "Paused until you allow the microphone."))
        }
        if access(.inputMonitoring) == .missing {
            lines.append(allowLine(.inputMonitoring, "The shortcut needs Input Monitoring."))
        }
        if dictationPastes, access(.accessibility) == .missing {
            lines.append(allowLine(.accessibility, "Pasting where you type needs Accessibility."))
        }
        if dictationReadsWindow, access(.screenRecording) == .missing {
            lines.append(allowLine(.screenRecording, "Compose needs Screen Recording to read the focused window."))
        }
        lines += relaunchLines([.inputMonitoring, .accessibility, .screenRecording])
        if let line = modelLine(.transcribe, focus: "settings.transcriptionModel") { lines.append(line) }
        let speechOnline: String?
        if case .remote(let host) = settings.transcriptionPresentation { speechOnline = host } else { speechOnline = nil }
        if let speechOnline {
            lines.append(SettingsStatusLine(id: "online.speech", tone: .online,
                                            text: SettingsText("What you say is sent to %@ to be turned into text.",
                                                               .verbatim(speechOnline)),
                                            action: .open(.models, focus: "settings.transcriptionModel")))
        } else if lines.isEmpty, let model = model(.transcribe) {
            lines.append(SettingsStatusLine(id: "ready", tone: .ok,
                                            text: SettingsText("Ready · %@, on this Mac", .verbatim(model.name)),
                                            action: .open(.models, focus: "settings.transcriptionModel")))
        }
        if settings.dictationIntent == .compose,
           case .remote(let host) = InferencePresentation(settings: settings.dictationCompositionTextEngineSettings) {
            lines.append(SettingsStatusLine(id: "online.compose", tone: .online,
                                            text: SettingsText("Compose sends what you dictate to %@, where Think runs.",
                                                               .verbatim(host)),
                                            action: .open(.models, focus: "settings.summarizerBackend")))
        }
        return lines
    }

    private var meetingLines: [SettingsStatusLine] {
        var lines: [SettingsStatusLine] = []
        if access(.microphone) == .missing {
            lines.append(allowLine(.microphone, "Paused until you allow the microphone."))
        }
        if access(.calendar) == .missing {
            lines.append(allowLine(.calendar, "Calendar access is off, so meetings aren’t matched to your events."))
        }
        let downloads = modelsToDownload.filter { $0.role != .autocomplete }
        if !downloads.isEmpty {
            lines.append(SettingsStatusLine(
                id: "model.download", tone: .need,
                text: SettingsText("%@ isn’t downloaded yet.",
                                   .verbatim(downloads.map(\.nameAndSize).joined(separator: ", "))),
                action: .download))
        }
        return lines
    }

    private var screenLines: [SettingsStatusLine] {
        guard settings.trackingEnabled else { return [offLine()] }
        var lines: [SettingsStatusLine] = []
        if access(.accessibility) == .missing {
            lines.append(allowLine(.accessibility, "Window titles and screen text need Accessibility."))
        }
        if settings.effectiveScreenContextCaptureMode.capturesPixels, access(.screenRecording) == .missing {
            lines.append(allowLine(.screenRecording, "Screen Recording is off, so visual screen context is paused."))
        }
        lines += relaunchLines([.accessibility, .screenRecording])
        return lines
    }
}

/// Back and forward through the Settings pages visited in this window.
struct SettingsPageHistory: Equatable {
    private(set) var back: [AppState.SettingsTab] = []
    private(set) var forward: [AppState.SettingsTab] = []
    private(set) var current: AppState.SettingsTab

    init(current: AppState.SettingsTab) {
        self.current = current
    }

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    /// A page chosen from the list, a search result or a deep link. Choosing
    /// the page already shown changes nothing.
    mutating func visit(_ page: AppState.SettingsTab) {
        guard page != current else { return }
        back.append(current)
        if back.count > 50 { back.removeFirst() }
        forward.removeAll()
        current = page
    }

    mutating func goBack() -> AppState.SettingsTab? {
        guard let page = back.popLast() else { return nil }
        forward.append(current)
        current = page
        return page
    }

    mutating func goForward() -> AppState.SettingsTab? {
        guard let page = forward.popLast() else { return nil }
        back.append(current)
        current = page
        return page
    }
}
