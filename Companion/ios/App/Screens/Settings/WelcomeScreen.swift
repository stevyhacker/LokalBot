import LokalBotCompanionKit
import SwiftUI

/// First launch: pair with the Mac, or look around the sample library.
struct WelcomeScreen: View {
    @Environment(CompanionSession.self) private var session
    @Environment(AppNavigator.self) private var navigator
    @State private var showingPairing = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Image("LokalBotMark")
                    .resizable()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Your work memory, on the go")
                        .font(LBTokens.Typography.pageTitle)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Read your meetings, action items, Timeline and Day Digests from LokalBot on your Mac, and ask it questions.")
                        .font(LBTokens.Typography.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 14) {
                    point("lock.shield", "Only between your devices",
                          "Your Mac sends its shared library straight to this device, end-to-end encrypted. LokalBot runs no server.")
                    point("wifi", "On your Wi-Fi or Tailscale",
                          "Syncs when both are on the same network, or from anywhere with Tailscale on both.")
                    point("checklist", "Mark actions done",
                          "Changes go back to your Mac on the next sync.")
                }
                VStack(spacing: 10) {
                    Button {
                        showingPairing = true
                    } label: {
                        Label("Pair with Your Mac", systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .primaryActionButton()
                    .controlSize(.large)
                    Button {
                        Task {
                            do {
                                try await session.showSampleLibrary()
                            } catch {
                                self.error = error.localizedDescription
                            }
                        }
                    } label: {
                        Text("Try It Without a Mac").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    if let error {
                        Text(error).workspaceTextRole(.warning)
                    }
                }
                Text("On your Mac, open LokalBot Settings → Phones & tablets → Add a Device to show the pairing code.")
                    .font(LBTokens.Typography.caption)
                    .workspaceSupportingForeground()
            }
            .padding(28)
            .frame(maxWidth: 520, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
        }
        .sheet(isPresented: $showingPairing) { PairingScreen(initialLink: navigator.demoPairingLink) }
        .task(id: navigator.demoPairingLink) { if navigator.demoPairingLink != nil { showingPairing = true } }
    }

    private func point(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(systemImage: icon, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(LBTokens.Typography.body.weight(.semibold))
                Text(detail).font(LBTokens.Typography.secondary).workspaceSupportingForeground()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
