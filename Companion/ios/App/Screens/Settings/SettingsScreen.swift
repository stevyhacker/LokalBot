import LokalBotCompanionKit
import SwiftUI

/// The paired Mac and how it's reached, what this device receives, App Lock,
/// and removing this device.
struct SettingsScreen: View {
    @Environment(CompanionSession.self) private var session
    @Environment(AppLock.self) private var appLock
    @State private var confirmingRemoval = false
    @State private var showingPairing = false
    @State private var localNetworkDenied = false
    @State private var storageBytes: Int64 = 0

    private let format = LBFormat.current

    var body: some View {
        Form {
            if session.mode == .sample {
                sampleSection
            } else {
                macSection
            }
            receivesSection
            Section {
                Toggle(isOn: Binding(get: { appLock.isEnabled }, set: { enabled in Task { await appLock.setEnabled(enabled) } })) {
                    Label("Require \(appLock.biometryName)", systemImage: "lock")
                }
                .disabled(!appLock.canLock)
                .tint(Brand.tealFill)
            } header: {
                Text("App Lock")
            } footer: {
                Text("LokalBot asks before showing your library, and hides it in the app switcher.")
            }
            Section {
                Button(role: .destructive) {
                    confirmingRemoval = true
                } label: {
                    Label(session.mode == .sample ? "Close the Sample Library" : "Remove This Device",
                          systemImage: session.mode == .sample ? "xmark.circle" : "trash")
                }
            } footer: {
                if session.mode == .paired {
                    Text("Erases everything LokalBot keeps on this device and forgets the pairing. Also remove it on your Mac in Settings → Phones & tablets.")
                }
            }
            Section {
                LabeledContent("Version", value: Bundle.main.versionLabel)
            } footer: {
                Text("LokalBot runs no server. Your library travels only between your own devices, end-to-end encrypted.")
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog(session.mode == .sample ? "Close the sample library?" : "Remove this device?",
                            isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button(session.mode == .sample ? "Close Sample Library" : "Remove and Erase", role: .destructive) {
                Task { await session.removeThisDevice() }
            }
        } message: {
            Text(session.mode == .sample ? "You'll return to the welcome screen."
                 : "Meetings, actions and answers on this device are erased. Your Mac keeps everything.")
        }
        .sheet(isPresented: $showingPairing) { PairingScreen() }
        .task(id: session.revision) {
            storageBytes = CompanionStorage.usedBytes()
        }
    }

    private var macSection: some View {
        Section {
            HStack(spacing: 12) {
                IconTile(systemImage: "desktopcomputer", size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.macName).font(LBTokens.Typography.body.weight(.semibold))
                    SyncStatusLine()
                }
            }
            .padding(.vertical, 4)
            if let route = NetworkRoute(address: session.status.lastAddress) {
                LabeledContent("Reached over") {
                    HStack(spacing: 6) {
                        Image(systemName: route.systemImage).foregroundStyle(Brand.teal).accessibilityHidden(true)
                        Text(route.label)
                    }
                }
            }
            LabeledContent("This device", value: DeviceName.current)
            if let last = session.status.lastSyncAt {
                LabeledContent("Last sync", value: format.ago(last, now: session.referenceDateOverride ?? Date()))
            }
            if session.status.pendingOps > 0 {
                LabeledContent("Waiting to send", value: "\(session.status.pendingOps) change\(session.status.pendingOps == 1 ? "" : "s")")
            }
            Button {
                Task { await session.syncNow() }
            } label: {
                HStack {
                    Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                    if session.isSyncing {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(session.isSyncing)
            if localNetworkDenied {
                Label("Local Network access is off for LokalBot, so it can't find your Mac on this Wi-Fi. Turn it on in Settings → Privacy & Security → Local Network. Tailscale still works.",
                      systemImage: "wifi.exclamationmark")
                    .font(LBTokens.Typography.secondary)
                    .foregroundStyle(LBTokens.Palette.attentionText)
            }
        } header: {
            Text("Paired Mac")
        } footer: {
            Text("Syncs on the same Wi-Fi, or from anywhere when both devices are on Tailscale. Your Mac needs to be awake with sharing on.")
        }
        .task {
            if case .localNetworkDenied = await MacDiscovery().discover(browseSeconds: 1) { localNetworkDenied = true }
        }
    }

    private var sampleSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label("You're looking at a sample library", systemImage: "shippingbox")
                    .font(LBTokens.Typography.body.weight(.semibold))
                Text("Pair with LokalBot on your Mac to see your own meetings, actions and days.")
                    .font(LBTokens.Typography.secondary)
                    .workspaceSupportingForeground()
            }
            .padding(.vertical, 4)
            Button {
                showingPairing = true
            } label: {
                Label("Pair with Your Mac", systemImage: "qrcode.viewfinder")
            }
        }
    }

    private var receivesSection: some View {
        let classes = session.manifest?.dataClasses ?? .init()
        let items: [(String, String, Bool)] = [
            ("Meetings and summaries", "waveform.circle", classes.meetings),
            ("Transcripts", "text.quote", classes.transcripts),
            ("Day Digests", "sparkles", classes.digests),
            ("Timeline", "calendar.day.timeline.left", classes.timeline),
            ("Window titles", "macwindow", classes.windowTitles),
            ("People", "person.2", classes.people),
            ("Projects", "folder", classes.projects),
        ]
        return Section {
            ForEach(items, id: \.0) { title, icon, on in
                LabeledContent {
                    Image(systemName: on ? "checkmark" : "minus")
                        .foregroundStyle(on ? Brand.teal : LBTokens.Palette.supporting)
                        .accessibilityLabel(on ? "Shared" : "Not shared")
                } label: {
                    Label(title, systemImage: icon)
                }
            }
            if let manifest = session.manifest {
                LabeledContent("History", value: manifest.historyDays == 0 ? "All" : "Last \(manifest.historyDays) days")
            }
            LabeledContent("Storage used", value: ByteCountFormatter.string(fromByteCount: storageBytes, countStyle: .file))
        } header: {
            Text("This Device Receives")
        } footer: {
            Text("Chosen on your Mac in Settings → Phones & tablets. Screenshots, screen text, audio, email and API keys never leave the Mac.")
        }
    }
}

extension Bundle {
    var versionLabel: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "–"
        return "\(version) (\(build))"
    }
}
