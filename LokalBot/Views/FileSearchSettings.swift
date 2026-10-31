import AppKit
import SwiftUI

/// Settings → Personal Context → Files. Nothing is read until the person
/// turns Files on after a notice and chooses a folder.
struct FileSearchSettingsSection: View {
    @EnvironmentObject var app: AppState
    let focusedSettingID: String?
    @State private var confirmingOn = false
    @State private var confirmingOff = false
    @State private var adding: FolderAddition?
    private let hasBattery = PowerSourceMonitor.hasBattery()

    static let readingDetails = "LokalBot reads only the folders listed here: pictures and screenshots, PDFs page by page, "
        + "and documents such as txt, md, rtf, docx, odt and html. It skips hidden folders, app bundles, caches, code "
        + "projects (except their screenshots), folders that look like datasets, and iCloud files that are not downloaded. "
        + "With recordings and video included, sound is read 30 seconds at a time and video a frame per shot, so a "
        + "search can open the moment in LokalBot's player. The index keeps each file's path, its text, and a vector of "
        + "what it says, shows or sounds like, in the LokalBot library. The image and text model downloads once and runs only while new or changed "
        + "files are read. Reading pauses while a meeting records, in Low Power Mode, and while the Mac is warm. "
        + "While you use the Mac, a folder's first read goes at about a third of full speed, and at full speed once "
        + "you step away. On battery it waits for a charger unless Read big folders on battery is on."

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
                if hasBattery {
                    Toggle(isOn: Binding(
                        get: { app.settings.fileSearchReadsOnBattery },
                        set: { on in app.changeSettings { $0.fileSearchReadsOnBattery = on } })) {
                        SettingsLabel("Read big folders on battery",
                                      help: "Off, a folder's first read waits until the Mac is plugged in. New files "
                                          + "are read right away either way.")
                    }
                    .settingTarget("settings.fileSearchReadsOnBattery", selected: focusedSettingID)
                }
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
        .sheet(item: $adding) { addition in
            FileFolderAddSheet(folders: addition.folders, files: app.fileSearch,
                               waitsForCharger: hasBattery && !app.settings.fileSearchReadsOnBattery) {
                app.changeSettings { settings in
                    for folder in addition.folders where !settings.fileSearchFolders.contains(folder) {
                        settings.fileSearchFolders.append(folder)
                    }
                }
            }
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
                .filter { !app.settings.fileSearchFolders.contains($0) }
            if !chosen.isEmpty { adding = FolderAddition(folders: chosen) }
        }
    }
}

private struct FolderAddition: Identifiable {
    let id = UUID()
    let folders: [String]
}

/// Before a folder is added: what it holds and how long its first read takes
/// on this Mac, counted from metadata while the sheet is open. Nothing is
/// read until the person adds it, and adding doesn't wait for the count.
struct FileFolderAddSheet: View {
    let folders: [String]
    @ObservedObject var files: FileSearchService
    let waitsForCharger: Bool
    let add: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var checked = 0
    @State private var estimate: FileFolderEstimate?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            title.font(.headline)
            if let estimate {
                summary(estimate)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Counting files… \(checked) so far")
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(folders.count == 1 ? "Add Folder" : "Add Folders") {
                    add()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("settings.files.confirmAdd")
            }
        }
        .padding(20)
        .frame(width: 460)
        .task {
            estimate = await files.estimate(of: folders) { checked = $0 }
        }
    }

    private var title: Text {
        folders.count == 1
            ? Text("Add “\(URL(fileURLWithPath: folders[0]).lastPathComponent)”?")
            : Text("Add \(folders.count) folders?")
    }

    @ViewBuilder private func summary(_ estimate: FileFolderEstimate) -> some View {
        if estimate.files == 0 {
            Text("LokalBot found nothing here it reads yet. New files are read as they arrive.")
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                if estimate.pictures > 0 {
                    GridRow { Text("Pictures"); Text(estimate.pictures, format: .number) }
                }
                if estimate.documents > 0 {
                    GridRow { Text("PDFs and documents"); Text(estimate.documents, format: .number) }
                }
                if estimate.recordings > 0 {
                    GridRow {
                        Text("Recordings and video")
                        Text("\(estimate.recordings) · \(Self.duration(estimate.playingSeconds))")
                    }
                }
                GridRow {
                    Text("First read").bold()
                    if estimate.seconds < 60 {
                        Text("Under a minute").bold()
                    } else {
                        Text("About \(Self.duration(estimate.seconds))").bold()
                    }
                }
                if estimate.laterSeconds >= 60 {
                    GridRow {
                        Text("Rest of long PDFs and documents")
                        Text("About \(Self.duration(estimate.laterSeconds)) more")
                    }
                }
            }
            .accessibilityIdentifier("settings.files.estimate")
            Text("Times are for this Mac at full speed. While you use the Mac, LokalBot reads at about a third of that and goes at full speed when you step away.")
                .workspaceTextRole(.metadata)
                .fixedSize(horizontal: false, vertical: true)
            if waitsForCharger, estimate.files > FileSearchService.newFilesLimit {
                Text("On battery, the first read waits for a charger.")
                    .workspaceTextRole(.metadata)
            }
        }
    }

    /// "25 min", "2 hr, 10 min": the precision an estimate deserves.
    static func duration(_ seconds: Double) -> String {
        let rounded = seconds < 3600 ? max(1, (seconds / 60).rounded()) * 60 : (seconds / 600).rounded() * 600
        return Duration.seconds(rounded).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
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
                if let left = files.secondsLeft, left >= 60 {
                    Text("About \(FileFolderAddSheet.duration(left)) left")
                        .workspaceTextRole(.metadata)
                }
            }
        case .finishingLongFiles(let left):
            Text("Reading the rest of \(left) long files")
        case .paused(.recording):
            Text("Paused while a meeting records.")
        case .paused(.lowPower):
            Text("Paused in Low Power Mode.")
        case .paused(.warm):
            Text("Paused while the Mac is warm.")
        case .waitingForPower(let left):
            Text("Waiting for a charger: \(left) files left to read.")
        case .ready:
            Text("Up to date.")
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .workspaceTextRole(.warning)
        }
    }
}
