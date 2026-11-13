import AppKit
import SwiftUI

/// The open panel behind every "Import Recording…" control.
enum RecordingImportPanel {
    @MainActor static func choose(into app: AppState) {
        let panel = NSOpenPanel()
        panel.title = app.settings.appLanguage.localized("Import Recording")
        panel.prompt = app.settings.appLanguage.localized("Import")
        panel.allowedContentTypes = MeetingImportService.contentTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        app.importRecordings(panel.urls)
    }
}

/// Accepts audio and video files dropped onto a view and imports them as
/// meetings. Other files are refused with a short explanation.
private struct RecordingImportDropTarget: ViewModifier {
    let app: AppState
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(MeetingImportService.isImportable)
                guard !files.isEmpty else {
                    if urls.contains(where: \.isFileURL) {
                        app.lastError = app.settings.appLanguage.localized(
                            "Drop an audio or video file to import it.")
                    }
                    return false
                }
                app.importRecordings(files)
                return true
            } isTargeted: { targeted = $0 }
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: Brand.Radius.panel)
                        .strokeBorder(Brand.teal, style: StrokeStyle(lineWidth: 2, dash: [6]))
                        .background(Brand.teal.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: Brand.Radius.panel))
                        .overlay {
                            Label("Drop to import", systemImage: "square.and.arrow.down")
                                .font(.scaled(.headline))
                                .foregroundStyle(Brand.teal)
                        }
                        .padding(6)
                        .allowsHitTesting(false)
                }
            }
    }
}

extension View {
    func recordingImportDropTarget(_ app: AppState) -> some View {
        modifier(RecordingImportDropTarget(app: app))
    }
}
