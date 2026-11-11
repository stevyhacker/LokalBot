import AppKit
import SwiftUI

/// One coding-agent note in Ask's results: the shared result anatomy (title ·
/// date · agent, then the matched words) under a note icon.
struct AgentNoteResultRow: View {
    let hit: AgentNoteHit
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "note.text")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                ResultRow(title: hit.title, kind: hit.sourceLabel,
                          snippet: hit.snippet.isEmpty ? (hit.summary ?? hit.path) : hit.snippet,
                          timestamp: hit.modified.formatted(date: .abbreviated, time: .omitted))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open") { open() }
            Button("Show in Finder") { AgentNoteOpener.reveal(hit) }
        }
        .help(hit.path)
        .accessibilityIdentifier("agentNote.hit.\(hit.id)")
    }
}

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
