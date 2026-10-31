import AppKit
import SwiftUI

/// Settings → Personal Context → Files. Nothing is read until the person
/// turns Files on after a notice and chooses a folder.
struct FileSearchSettingsSection: View {
    @EnvironmentObject var app: AppState
    let focusedSettingID: String?
    @State private var confirmingOn = false
    @State private var confirmingOff = false

    static let readingDetails = "LokalBot reads only the folders listed here: pictures and screenshots, PDFs page by page, "
        + "and documents such as txt, md, rtf, docx, odt and html. It skips hidden folders, app bundles, caches, code "
        + "projects (except their screenshots), folders that look like datasets, and iCloud files that are not downloaded. "
        + "With recordings and video included, sound is read 30 seconds at a time and video a frame per shot, so a "
        + "search can open the moment in LokalBot's player. The index keeps each file's path, its text, and a vector of "
        + "what it says, shows or sounds like, in the LokalBot library. The image and text model downloads once and runs only while new or changed "
        + "files are read. Reading pauses while a meeting records, in Low Power Mode, and while the Mac is warm."

    var body: some View {
        Section("Files") {
            SettingsHelp("Search the folders you choose by what is in them: documents and PDFs by their words and meaning, "
                         + "pictures and screenshots by what they show. Files are read on this Mac and never changed.")
                .settingTarget("settings.fileSearchEnabled", selected: focusedSettingID)
            Toggle("Search my files", isOn: Binding(
                get: { app.settings.fileSearchEnabled },
                set: { on in if on { confirmingOn = true } else { confirmingOff = true } }))
                .accessibilityIdentifier("settings.files.enabled")
            if app.settings.fileSearchEnabled {
                ForEach(app.settings.fileSearchFolders, id: \.self) { folder in
                    folderRow(folder)
                }
                Toggle(isOn: Binding(
                    get: { app.settings.fileSearchIncludesMedia },
                    set: { on in app.changeSettings { $0.fileSearchIncludesMedia = on } })) {
                    SettingsLabel("Include recordings and video",
                                  help: "Sound is read 30 seconds at a time and video a frame per shot. A first pass "
                                      + "over hours of video takes a while.")
                }
                .settingTarget("settings.fileSearchIncludesMedia", selected: focusedSettingID)
                Button("Add Folder…", action: chooseFolders)
                    .accessibilityIdentifier("settings.files.addFolder")
                    .settingTarget("settings.fileSearchFolders", selected: focusedSettingID)
                FileSearchStatusView(files: app.fileSearch)
            }
            SettingsDetails("What LokalBot reads", Self.readingDetails)
        }
        .alert("Search your files?", isPresented: $confirmingOn) {
            Button("Turn On") { app.changeSettings { $0.fileSearchEnabled = true } }
            Button("Privacy Policy") { NSWorkspace.shared.open(Self.privacyPolicyURL) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("LokalBot reads the folders you choose and keeps an index of their text, pictures and sound in its library. Nothing leaves this Mac. The first time, it downloads EmbeddingGemma 2's image model (555 MB). Turning Files off deletes the index.")
        }
        .confirmationDialog("Turn off Files?", isPresented: $confirmingOff) {
            Button("Turn Off and Delete the Index", role: .destructive) {
                app.changeSettings { $0.fileSearchEnabled = false }
            }
        } message: {
            Text("LokalBot stops reading the chosen folders and deletes the file index. Your files are not touched.")
        }
    }

    static let privacyPolicyURL = URL(string: "https://www.lokalbot.com/privacy#files")!

    private func folderRow(_ folder: String) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: folder))
                .resizable()
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
            Text(verbatim: (folder as NSString).abbreviatingWithTildeInPath)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if !FileManager.default.fileExists(atPath: folder) {
                Text("Not available")
                    .workspaceTextRole(.metadata)
            }
            Button("Remove") {
                app.changeSettings { $0.fileSearchFolders.removeAll { $0 == folder } }
            }
            .controlSize(.small)
        }
    }

    private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.title = app.settings.appLanguage.localized("Choose folders to search")
        panel.prompt = app.settings.appLanguage.localized("Choose")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = true
        panel.begin { response in
            guard response == .OK else { return }
            let chosen = panel.urls.map { $0.standardizedFileURL.path }
            app.changeSettings { settings in
                for folder in chosen where !settings.fileSearchFolders.contains(folder) {
                    settings.fileSearchFolders.append(folder)
                }
            }
        }
    }
}

/// What Files is doing now, and what the index holds.
struct FileSearchStatusView: View {
    @ObservedObject var files: FileSearchService

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            state
            if files.totals.searchable > 0 {
                Text("\(files.totals.searchable) files searchable · index \(ByteCountFormatter.string(fromByteCount: files.totals.indexBytes, countStyle: .file))")
                    .workspaceTextRole(.metadata)
            }
            if let pass = files.lastPass, pass.filesRead > 0 {
                Text("Last pass read \(pass.filesRead) files in \(Duration.seconds(pass.wallSeconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))).")
                    .workspaceTextRole(.metadata)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.files.status")
    }

    @ViewBuilder private var state: some View {
        switch files.state {
        case .off:
            EmptyView()
        case .noFolders:
            Text("Choose a folder to start.")
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 4) {
                Text("Downloading the image and text model…")
                if let fraction { ProgressView(value: fraction).frame(maxWidth: 240) }
            }
        case .indexing(let done, let total):
            VStack(alignment: .leading, spacing: 4) {
                Text("Reading files: \(done) of \(total)")
                ProgressView(value: Double(done), total: Double(max(total, 1))).frame(maxWidth: 240)
            }
        case .finishingLongFiles(let left):
            Text("Reading the rest of \(left) long files")
        case .paused(.recording):
            Text("Paused while a meeting records.")
        case .paused(.lowPower):
            Text("Paused in Low Power Mode.")
        case .paused(.warm):
            Text("Paused while the Mac is warm.")
        case .ready:
            Text("Up to date.")
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .workspaceTextRole(.warning)
        }
    }
}
