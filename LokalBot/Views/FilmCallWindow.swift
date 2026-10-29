#if LOKALBOT_UI_TEST_HOST
import AppKit
import SwiftUI

/// UI-test host only: with `LOKALBOT_UI_TEST_CALL=1`, Start Radar also opens
/// a stand-in video call behind the floating Live Radar panel, so the
/// hackathon film shows the panel over a call the way it is used. The call
/// shows the live script's words as they arrive in the live transcript, so
/// its captions and speaking tiles keep time with the radar. Open LokalBot in
/// the panel closes it, which brings the LokalBot window behind it forward.
@MainActor
enum FilmCall {
    static var isRequested: Bool { ProcessInfo.processInfo.environment["LOKALBOT_UI_TEST_CALL"] == "1" }
    private static var window: NSWindow?

    static func show(app: AppState, title: String) {
        guard isRequested, window == nil, let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame.insetBy(dx: 10, dy: 6)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = title
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let you = app.settings.cotypingUserName.isEmpty ? "You" : app.settings.cotypingUserName
        window.contentView = NSHostingView(rootView: FilmCallView(transcriber: app.liveTranscriber, title: title, you: you))
        window.setFrame(frame, display: true)
        window.orderFront(nil)
        self.window = window
    }

    /// Closes the call; false when none is open.
    @discardableResult
    static func close() -> Bool {
        guard let window else { return false }
        window.close()
        self.window = nil
        return true
    }
}

private struct FilmCallView: View {
    @ObservedObject var transcriber: LiveMeetingTranscriber
    let title: String
    let you: String
    @State private var started = Date()

    private static let them = "Ana Petrović"
    private var speaking: String? { transcriber.partials.first?.speaker }
    private var caption: LiveMeetingTranscriber.Line? { transcriber.partials.first ?? transcriber.lines.last }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "video.fill").foregroundStyle(.green)
                Text(verbatim: title).font(.system(size: 15, weight: .semibold))
                TimelineView(.periodic(from: started, by: 1)) { context in
                    let seconds = Int(context.date.timeIntervalSince(started))
                    Text(verbatim: String(format: "%02d:%02d", seconds / 60, seconds % 60))
                        .font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer()
                Label { Text(verbatim: "2") } icon: { Image(systemName: "person.2.fill") }
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .padding(.top, 30)
            HStack(spacing: 14) {
                tile(name: Self.them, initials: "AP", hue: 0.55, speaker: "them")
                tile(name: "\(you) (You)", initials: initials(of: you), hue: 0.42, speaker: "local")
            }
            captionBar
            HStack(spacing: 18) {
                control("mic.fill")
                control("video.fill")
                control("rectangle.on.rectangle")
                control("captions.bubble.fill")
                control("phone.down.fill", tint: .red)
            }
            .padding(.bottom, 16)
        }
        // The floating panel sits over the call's right side, as it would over a meeting app.
        .padding(.leading, 22)
        .padding(.trailing, LiveRadarPanelController.width + 30)
        .background(Color(red: 0.09, green: 0.10, blue: 0.11))
        // One element: XCUITest reads the app's whole tree a few times a
        // second during the film, and the call's views slowed the script down.
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("filmCall")
    }

    private func tile(name: String, initials: String, hue: Double, speaker: String) -> some View {
        let isSpeaking = speaking == speaker
        return ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 16)
                .fill(LinearGradient(colors: [Color(hue: hue, saturation: 0.35, brightness: 0.30),
                                              Color(hue: hue, saturation: 0.40, brightness: 0.16)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle()
                .fill(Color(hue: hue, saturation: 0.45, brightness: 0.85))
                .frame(width: 128, height: 128)
                .overlay(Text(verbatim: initials).font(.system(size: 46, weight: .bold)).foregroundStyle(.black.opacity(0.75)))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 8) {
                Image(systemName: isSpeaking ? "waveform" : "mic.fill")
                    .foregroundStyle(isSpeaking ? .green : .white.opacity(0.7))
                Text(verbatim: name).font(.system(size: 14, weight: .semibold))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
            .padding(12)
        }
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(isSpeaking ? Color.green : .clear, lineWidth: 3))
        .animation(.easeOut(duration: 0.2), value: isSpeaking)
    }

    private var captionBar: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let caption {
                Text(verbatim: caption.speaker == "local" ? you : Self.them)
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(.white.opacity(0.75))
                Text(verbatim: caption.text).font(.system(size: 19, weight: .medium))
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(verbatim: " ").font(.system(size: 19))
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .frame(maxWidth: 980)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }

    private func control(_ symbol: String, tint: Color = Color(white: 0.24)) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .semibold))
            .frame(width: 50, height: 50)
            .background(tint, in: Circle())
    }

    private func initials(of name: String) -> String {
        String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
    }
}
#endif
