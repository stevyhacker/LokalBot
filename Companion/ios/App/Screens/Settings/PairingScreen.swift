import AVFoundation
import LokalBotCompanionKit
import SwiftUI

/// Pairing: scan the code the Mac shows (or paste its link), confirm the
/// Mac's name, then wait while the person allows it on the Mac.
struct PairingScreen: View {
    @Environment(CompanionSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    /// A link to start from (debug screenshots); otherwise the person scans or pastes one.
    var initialLink: String?

    private enum Step: Equatable {
        case scan
        case confirm(PairingPayload, link: String)
        case waiting(macName: String)
        case paired(macName: String)
        case failed(String)
    }

    @State private var step: Step
    @State private var pasted = ""
    @State private var cameraAllowed: Bool?
    @State private var deviceName = ""
    @FocusState private var nameFocused: Bool

    init(initialLink: String? = nil) {
        self.initialLink = initialLink
        _step = State(initialValue: initialLink.map(Self.step(reading:)) ?? .scan)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch step {
                    case .scan: scan
                    case .confirm(let payload, let link): confirm(payload, link: link)
                    case .waiting(let macName): waiting(macName)
                    case .paired(let macName): paired(macName)
                    case .failed(let message): failed(message)
                    }
                }
                .padding(24)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Pair with Your Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(stepIsPaired ? "Done" : "Cancel") { dismiss() }
                }
            }
            .workspaceAnimation(.milestone, value: step)
        }
        .interactiveDismissDisabled(isWaiting)
        .task {
            if deviceName.isEmpty { deviceName = DeviceName.current }
        }
    }

    private var stepIsPaired: Bool { if case .paired = step { true } else { false } }
    private var isWaiting: Bool { if case .waiting = step { true } else { false } }

    // MARK: Steps

    @ViewBuilder private var scan: some View {
        Text("On your Mac, open LokalBot Settings → Phones & tablets → Add a Device, then point the camera at the code.")
            .font(LBTokens.Typography.body)
            .fixedSize(horizontal: false, vertical: true)
        Group {
            if cameraAllowed == true, QRScannerView.isAvailable {
                QRScannerView { code in
                    if case .scan = step { read(code) }
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "camera").font(.system(size: 30)).foregroundStyle(LBTokens.Palette.supporting)
                    Text(cameraAllowed == false
                         ? "Camera access is off for LokalBot. Allow it in Settings, or paste the pairing link below."
                         : "The camera isn't available here. Paste the pairing link below.")
                        .font(LBTokens.Typography.secondary)
                        .multilineTextAlignment(.center)
                        .workspaceSupportingForeground()
                }
                .padding(24)
                .frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 300)
        .clipShape(RoundedRectangle(cornerRadius: LBTokens.Radius.card, style: .continuous))
        .lbGroupedSurface()
        // Ask for the camera only when there is something to scan.
        .task { if cameraAllowed == nil { cameraAllowed = await Self.requestCamera() } }
        VStack(alignment: .leading, spacing: 8) {
            Text("Or paste the link").font(LBTokens.Typography.section)
            Text("On the Mac, choose Copy Link under the code and send it to this device.")
                .font(LBTokens.Typography.secondary)
                .workspaceSupportingForeground()
            HStack(spacing: 8) {
                TextField("lokalbot://pair?d=…", text: $pasted)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(LBTokens.Typography.secondary.monospaced())
                    .padding(10)
                    .lbGroupedSurface()
                PasteButton(payloadType: String.self) { strings in
                    if let text = strings.first { pasted = text; read(text) }
                }
                .labelStyle(.iconOnly)
                .buttonBorderShape(.roundedRectangle)
                .tint(Brand.tealFill)
            }
            Button("Continue") { read(pasted) }
                .primaryActionButton()
                .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func confirm(_ payload: PairingPayload, link: String) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                IconTile(systemImage: "desktopcomputer", size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(payload.macName).font(LBTokens.Typography.columnTitle)
                    Text(payload.addresses.prefix(3).joined(separator: " · "))
                        .font(LBTokens.Typography.caption.monospaced())
                        .workspaceSupportingForeground()
                        .lineLimit(2)
                }
            }
            Text("This device will receive the meetings, actions, Timeline and digests your Mac shares, end-to-end encrypted. You'll allow it on the Mac next.")
                .font(LBTokens.Typography.body)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Name this device").font(LBTokens.Typography.section)
                TextField("Name", text: $deviceName, prompt: Text(UIDevice.current.model))
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .focused($nameFocused)
                    .padding(12)
                    .lbGroupedSurface()
                    .accessibilityLabel("Name this device")
                Text("Your Mac shows this name when it asks to allow this device, and in its list of devices.")
                    .font(LBTokens.Typography.caption)
                    .workspaceSupportingForeground()
            }
            Button {
                pair(link, macName: payload.macName)
            } label: {
                Text("Pair with \(payload.macName)").frame(maxWidth: .infinity)
            }
            .primaryActionButton()
            .controlSize(.large)
            .disabled(deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Scan Again") { step = .scan }
                .buttonStyle(.workspaceLink)
        }
    }

    private func waiting(_ macName: String) -> some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text("Waiting for your Mac").font(LBTokens.Typography.columnTitle)
            Text("On \(macName), click Allow to let “\(DeviceName.current)” read your shared LokalBot library.")
                .font(LBTokens.Typography.body)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private func paired(_ macName: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 52)).foregroundStyle(Brand.teal)
            Text("Paired with \(macName)").font(LBTokens.Typography.columnTitle).multilineTextAlignment(.center)
            Text("Your library is syncing now, newest first.")
                .font(LBTokens.Typography.body)
                .workspaceSupportingForeground()
            Button("Done") { dismiss() }
                .primaryActionButton()
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Couldn't pair", systemImage: "exclamationmark.triangle")
                .font(LBTokens.Typography.columnTitle)
                .foregroundStyle(LBTokens.Palette.attentionText)
            Text(message).font(LBTokens.Typography.body).fixedSize(horizontal: false, vertical: true)
            Button("Try Again") { step = .scan }
                .primaryActionButton()
        }
    }

    // MARK: Actions

    private func read(_ text: String) {
        step = Self.step(reading: text)
    }

    private static func step(reading text: String) -> Step {
        do {
            let payload = try PairingPayload.parse(text)
            if payload.isExpired() { return .failed(CompanionStoreError.pairingExpired.errorDescription ?? "") }
            return .confirm(payload, link: text)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func pair(_ link: String, macName: String) {
        nameFocused = false
        step = .waiting(macName: macName)
        Task {
            do {
                try await StoreFactory.useDeviceName(deviceName, in: session)
                let mac = try await session.pair(payload: link)
                step = .paired(macName: mac.macName)
            } catch {
                step = .failed(error.localizedDescription)
            }
        }
    }

    private static func requestCamera() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }
}
