import AppKit
import SwiftUI

/// Opens the agent's own file for a note in its default app. LokalBot keeps a
/// copy for search only and never edits the file.
@MainActor
enum AgentNoteOpener {
    static func open(_ hit: AgentNoteHit) {
        let url = URL(fileURLWithPath: hit.path)
        guard FileManager.default.fileExists(atPath: hit.path) else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open(url)
    }

    static func reveal(_ hit: AgentNoteHit) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: hit.path)])
    }
}
