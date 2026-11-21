import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AdditionalCallAppsEditor: View {
    @EnvironmentObject private var app: AppState
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent {
                Button(action: chooseApp) {
                    Label("Choose App…", systemImage: "plus")
                }
                .accessibilityIdentifier("settings.additionalCallApps.add")
            } label: {
                SettingsLabel("Additional call apps", help: "LokalBot detects calls in the apps you add here.")
            }
            ForEach(app.settings.additionalCallApps) { callApp in
                Divider()
                appRow(callApp)
            }
            if let error {
                Text(LocalizedStringKey(error)).workspaceTextRole(.warning)
                    .accessibilityIdentifier("settings.additionalCallApps.error")
            }
        }
    }

    private func appRow(_ callApp: AdditionalCallApp) -> some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: callApp.identifier)
        let name = callApp.name ?? url.flatMap(Bundle.init(url:)).map(AdditionalCallApp.applicationName(in:))
            ?? callApp.identifier.split(separator: ".").last.map(String.init) ?? callApp.identifier
        return HStack(spacing: 8) {
            Group {
                if let url {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
                } else {
                    Image(systemName: "app").foregroundStyle(.secondary)
                }
            }
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)
            Text(verbatim: name)
            Spacer()
            Button {
                app.changeSettings { $0.additionalCallApps.removeAll { $0.id == callApp.id } }
                error = nil
            } label: {
                Image(systemName: "trash").frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Remove from call detection")
            .accessibilityLabel(Text("Remove \(name) from call detection"))
            .accessibilityIdentifier("settings.additionalCallApps.remove.\(callApp.id)")
        }
    }

    private func chooseApp() {
        error = nil
        let panel = NSOpenPanel()
        panel.title = app.settings.appLanguage.catalog("Choose a call app")
        panel.prompt = app.settings.appLanguage.catalog("Add")
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let callApp = AdditionalCallApp(applicationURL: url),
              callApp.identifier != Bundle.main.bundleIdentifier else {
            error = "Choose a call app"
            return
        }
        guard !MeetingDetector.hasBuiltInCallDetection(callApp.identifier) else {
            error = "LokalBot already supports this app."
            return
        }
        guard !app.settings.additionalCallBundleIDs.contains(callApp.id) else {
            error = "This app is already on the list."
            return
        }
        app.changeSettings { $0.additionalCallApps.append(callApp) }
    }
}
