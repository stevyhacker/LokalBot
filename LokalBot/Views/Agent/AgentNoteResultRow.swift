import AppKit
import SwiftUI

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
