import SwiftUI

/// Settings → Phones & tablets. Turning sharing on starts a listener for
/// paired devices on the local network and Tailscale; everything below the
/// switch only exists while it is on.
struct CompanionSettingsSections: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        Section("Phones & tablets") {
            Toggle(isOn: $app.settings.companionSharingEnabled) {
                SettingsLabel("Share with my phones and tablets",
                              help: "Your iPhone, iPad, or Android device keeps an encrypted copy of what you choose below and reaches this Mac over your local network or Tailscale only. Nothing listens while this is off.")
            }
            .accessibilityIdentifier("settings.companionSharingEnabled")
            .settingTarget("settings.companionSharingEnabled", selected: app.focusedSettingID)
            if app.settings.companionSharingEnabled {
                CompanionStatusRow(host: app.companion, language: app.settings.appLanguage)
            }
        }
        if app.settings.companionSharingEnabled {
            CompanionDevicesSection(host: app.companion)
                .settingTarget("settings.companionDevices", selected: app.focusedSettingID)
            sharedDataSection
            questionsSection
            networkSection
        }
    }

    private var sharedDataSection: some View {
        Section("What your devices receive") {
            Toggle(isOn: $app.settings.companionShareMeetings) {
                SettingsLabel("Share meetings",
                              help: "Titles, times, people's names, projects, summaries, your notes, actions, decisions, and open questions.")
            }
            .settingTarget("settings.companionShareMeetings", selected: app.focusedSettingID)
            Toggle(isOn: $app.settings.companionShareTranscripts) {
                SettingsLabel("Share transcripts", help: "Transcript text with times and speaker names.")
            }
            .disabled(!app.settings.companionShareMeetings)
            .settingTarget("settings.companionShareTranscripts", selected: app.focusedSettingID)
            Toggle(isOn: $app.settings.companionShareDigests) {
                SettingsLabel("Share Day Digests",
                              help: "Each day's digest. Screen citations show only their time.")
            }
            .settingTarget("settings.companionShareDigests", selected: app.focusedSettingID)
            Toggle(isOn: $app.settings.companionShareTimeline) {
                SettingsLabel("Share the Timeline",
                              help: "Work sessions, apps, time per project, coding-agent sessions, and saved moments.")
            }
            .settingTarget("settings.companionShareTimeline", selected: app.focusedSettingID)
            Toggle(isOn: $app.settings.companionShareWindowTitles) {
                SettingsLabel("Include window titles",
                              help: "Titles your Mac's retention already cleared stay cleared.")
            }
            .disabled(!app.settings.companionShareTimeline)
            .settingTarget("settings.companionShareWindowTitles", selected: app.focusedSettingID)
            Toggle(isOn: $app.settings.companionSharePeople) {
                SettingsLabel("Share people", help: "Names, open work, decisions, and meetings together.")
            }
            .settingTarget("settings.companionSharePeople", selected: app.focusedSettingID)
            Toggle(isOn: $app.settings.companionShareProjects) {
                SettingsLabel("Share projects",
                              help: "Tracked projects with where they stand, actions, decisions, and time.")
            }
            .settingTarget("settings.companionShareProjects", selected: app.focusedSettingID)
            Picker(selection: $app.settings.companionHistory) {
                ForEach(CompanionHistoryWindow.allCases) { window in
                    Text(LocalizedStringKey(window.displayName)).tag(window)
                }
            } label: {
                SettingsLabel("Shared history", help: "Older records are removed from your devices.")
            }
            .settingTarget("settings.companionHistory", selected: app.focusedSettingID)
            SettingsHelp("Never shared: attendee email addresses, speaker evidence and voice profiles, screenshots and screen text, email, Personal Context, overnight memory, settings, and keys.")
        }
    }

    private var questionsSection: some View {
        Section("Questions") {
            Toggle(isOn: $app.settings.companionAnswersQuestions) {
                SettingsLabel("Answer questions from my devices",
                              help: "This Mac answers with your Think model and its approvals, from the meetings and Timeline you share. Screen memory is never searched for a device.")
            }
            .settingTarget("settings.companionAnswersQuestions", selected: app.focusedSettingID)
            if app.settings.companionAnswersQuestions {
                let language = app.settings.appLanguage
                InferenceDisclosure(
                    settings: app.settings,
                    localText: language.localized("Answers are written on this Mac."),
                    remoteText: String(
                        format: language.localized("Questions from your devices and the context they need go to your approved Think server (%@)."),
                        app.settings.summarizerBackend.displayName))
            }
        }
    }

    private var networkSection: some View {
        Section("Network") {
            CompanionPortField(port: $app.settings.companionPort)
                .settingTarget("settings.companionPort", selected: app.focusedSettingID)
            Toggle(isOn: $app.settings.companionAdvertisesOnBonjour) {
                SettingsLabel("Advertise on the local network",
                              help: "Devices on the same Wi-Fi find this Mac by itself. Turn off to use only the addresses saved when a device paired, such as Tailscale.")
            }
            .settingTarget("settings.companionAdvertisesOnBonjour", selected: app.focusedSettingID)
            SettingsDetails("How it works", "This Mac accepts connections only from private network addresses and Tailscale, and only from devices you paired by scanning a code and allowing them here. Every connection is end-to-end encrypted with the Noise protocol. Phones sync whenever they can reach this Mac and keep their copy for offline reading. LokalBot runs no server and receives nothing.")
        }
    }
}

private struct CompanionStatusRow: View {
    @ObservedObject var host: CompanionHost
    let language: AppLanguage

    var body: some View {
        LabeledContent("Status") {
            switch host.status {
            case .off:
                MemoryHealthStatus(value: language.localized("Off"), tone: .idle)
            case .starting:
                MemoryHealthStatus(value: language.localized("Starting…"), tone: .idle)
            case .listening(let port):
                MemoryHealthStatus(
                    value: String(format: language.localized("Listening on port %@"), String(port)),
                    tone: .good)
            case .failed(let message):
                VStack(alignment: .trailing, spacing: 4) {
                    MemoryHealthStatus(value: language.localized("Unavailable"), tone: .attention)
                    Text(message).font(AppFont.scaled(.callout)).settingsSecondary()
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }
}

private struct CompanionDevicesSection: View {
    @ObservedObject var host: CompanionHost
    @State private var removing: CompanionPairedDevice?

    var body: some View {
        Section("Devices") {
            if let offer = host.pairing {
                CompanionPairingPanel(offer: offer, cancel: host.cancelPairing)
            } else {
                LabeledContent {
                    Button("Add a Device…", action: host.beginPairing)
                        .disabled(!host.isListening)
                        .accessibilityIdentifier("settings.companionAddDevice")
                } label: {
                    SettingsLabel("Add a device",
                                  help: "Shows a code to scan with LokalBot on your phone or tablet. The device must be able to reach this Mac.")
                }
            }
            if host.devices.isEmpty {
                Text("No devices yet.").settingsSecondary()
            }
            ForEach(host.devices) { device in
                CompanionDeviceRow(device: device, connected: host.connectedDeviceIDs.contains(device.id)) {
                    removing = device
                }
            }
            if let error = host.actionError {
                Text(error).workspaceTextRole(.warning)
            }
        }
        .confirmationDialog(
            Text("Remove “\(removing?.name ?? "")”?"),
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { device in
            Button("Remove Device", role: .destructive) { host.removeDevice(device) }
        } message: { _ in
            Text("It can no longer connect, and if it is connected now it erases its copy.")
        }
    }
}

private struct CompanionDeviceRow: View {
    @EnvironmentObject private var app: AppState
    let device: CompanionPairedDevice
    let connected: Bool
    let remove: () -> Void

    var body: some View {
        LabeledContent {
            Button("Remove…", role: .destructive, action: remove)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(Brand.teal)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: device.name)
                    Text(verbatim: detail).font(AppFont.scaled(.callout)).settingsSecondary()
                }
            }
        }
    }

    private var icon: String {
        switch device.platform.lowercased() {
        case "ipados": "ipad"
        case "android": "smartphone"
        default: "iphone"
        }
    }

    private var detail: String {
        let language = app.settings.appLanguage
        var parts = [language.localized(CompanionPairingPrompt.platformName(device.platform))]
        if connected {
            parts.append(language.localized("Connected"))
        } else if let seen = device.lastSeenAt {
            parts.append(String(format: language.localized("Last seen %@"),
                                seen.formatted(.relative(presentation: .named))))
        } else {
            parts.append(language.localized("Not connected yet"))
        }
        if let network = device.network { parts.append(language.localized(network.label)) }
        return parts.joined(separator: " · ")
    }
}

private struct CompanionPairingPanel: View {
    let offer: CompanionPairingOffer
    let cancel: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            if let image = CompanionQRCode.image(for: offer.qrPayload) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 180, height: 180)
                    .padding(8)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: Brand.Radius.control))
                    .accessibilityLabel("Pairing code")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Scan with LokalBot on your phone or tablet")
                    .font(AppFont.scaled(.headline))
                Text("Open LokalBot on the device, choose Pair with a Mac, and point the camera at this code. Then allow the device here.")
                    .font(AppFont.scaled(.callout)).settingsSecondary()
                    .fixedSize(horizontal: false, vertical: true)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = max(0, Int(offer.expiresAt.timeIntervalSince(context.date)))
                    Text(remaining > 0
                         ? "Expires in \(String(format: "%d:%02d", remaining / 60, remaining % 60))"
                         : "This code expired. Cancel and add the device again.")
                        .font(AppFont.scaled(.callout).monospacedDigit())
                        .settingsSecondary()
                }
                Button("Cancel", action: cancel)
            }
        }
        .padding(.vertical, 4)
    }
}

/// The listener's port, applied when editing ends so a half-typed number
/// never restarts the listener.
private struct CompanionPortField: View {
    @Binding var port: Int
    @State private var text = ""

    var body: some View {
        LabeledContent {
            TextField("Port", text: $text)
                .labelsHidden()
                .frame(width: 80)
                .multilineTextAlignment(.trailing)
                .onSubmit(commit)
                .onAppear { text = String(port) }
                .onChange(of: port) { text = String(port) }
        } label: {
            SettingsLabel("Port", help: "Change it only if another app already uses this port.")
        }
    }

    private func commit() {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)) else {
            text = String(port)
            return
        }
        port = CompanionSharing.clampedPort(value)
        text = String(port)
    }
}
