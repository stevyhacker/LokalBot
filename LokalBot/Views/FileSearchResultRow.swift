import AppKit
import AVFoundation
import AVKit
import PDFKit
import SwiftUI

/// One file in Ask's results: the file's icon, then the shared result anatomy
/// (name · date · kind, the matched words or the folder it lives in).
struct FileSearchResultRow: View {
    let hit: FileSearchHit
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: hit.path))
                    .resizable()
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                ResultRow(title: hit.name, kind: hit.kindLabel, snippet: hit.excerpt ?? hit.folder,
                          timestamp: hit.date.formatted(date: .abbreviated, time: .omitted),
                          matchLabel: hit.isSemantic ? "Related by meaning" : nil)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open") { open() }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([hit.url]) }
        }
        .help(hit.folder)
        .accessibilityIdentifier("file.hit.\(hit.id)")
    }
}

/// Opens a file found by search. A PDF opens in a LokalBot window at the
/// matched page with the query's words marked; a recording or video plays in
/// a LokalBot window from the matched moment (no QuickTime scripting, so no
/// Automation permission); anything else opens in its default app.
@MainActor
enum FileSearchOpener {
    private static var windows: [ObjectIdentifier: NSWindow] = [:]

    static func open(_ hit: FileSearchHit, query: String?) {
        guard FileManager.default.fileExists(atPath: hit.path) else { return }
        if hit.kind == .audio || hit.kind == .video {
            play(hit)
            return
        }
        guard hit.kind == .pdf, let document = PDFDocument(url: hit.url) else {
            NSWorkspace.shared.open(hit.url)
            return
        }
        let view = PDFView()
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        let page = hit.page.flatMap { document.page(at: max(0, $0 - 1)) }
        if let page {
            view.go(to: page)
            view.highlightedSelections = highlights(of: query, in: document, on: page)
        }
        present(view, title: hit.page.map { "\(hit.name) — page \($0)" } ?? hit.name, url: hit.url,
                size: NSSize(width: 780, height: 920))
    }

    /// Plays from the matched moment: the start of its 30-second sound
    /// window, or the frame's time.
    private static func play(_ hit: FileSearchHit) {
        let player = AVPlayer(url: hit.url)
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = hit.kind == .video
        let start = CMTime(seconds: max(0, hit.seconds ?? 0), preferredTimescale: 600)
        player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            Task { @MainActor in player.play() }
        }
        let title = hit.seconds.map { "\(hit.name) — \(Transcript.stamp($0))" } ?? hit.name
        present(view, title: title, url: hit.url,
                size: hit.kind == .video ? NSSize(width: 960, height: 600) : NSSize(width: 560, height: 120)) {
            player.pause()
        }
    }

    private static func present(_ view: NSView, title: String, url: URL, size: NSSize,
                                onClose: @escaping @MainActor () -> Void = {}) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.representedURL = url
        window.contentView = view
        window.isReleasedWhenClosed = false
        window.center()
        let key = ObjectIdentifier(window)
        windows[key] = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                               queue: .main) { _ in
            Task { @MainActor in
                onClose()
                windows[key] = nil
            }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// The query's words (three letters or more) wherever they occur on the page.
    static func highlights(of query: String?, in document: PDFDocument, on page: PDFPage) -> [PDFSelection] {
        let terms = Set((query ?? "").lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 3 })
        return terms.flatMap { term in
            document.findString(term, withOptions: [.caseInsensitive, .diacriticInsensitive])
                .filter { $0.pages.contains(page) }
        }.map { selection in
            selection.color = NSColor.systemYellow.withAlphaComponent(0.5)
            return selection
        }
    }
}
