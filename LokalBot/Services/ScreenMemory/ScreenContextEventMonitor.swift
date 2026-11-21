import AppKit
import Foundation

enum ScreenContextInteraction: Sendable {
    case click
    case keyDown
    case scrollWheel
}

final class ScreenContextEventCoalescer: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "me.dotenv.LokalBot.screen-context-events",
        qos: .utility)
    private let typingDelay: TimeInterval
    private let scrollDelay: TimeInterval
    private let emit: @Sendable (ScreenCaptureTrigger) -> Void
    private var typingTimer: DispatchSourceTimer?
    private var scrollTimer: DispatchSourceTimer?
    private var isCancelled = false

    init(
        typingDelay: TimeInterval = 0.8,
        scrollDelay: TimeInterval = 0.55,
        emit: @escaping @Sendable (ScreenCaptureTrigger) -> Void
    ) {
        self.typingDelay = typingDelay
        self.scrollDelay = scrollDelay
        self.emit = emit
    }

    func receive(_ interaction: ScreenContextInteraction) {
        queue.async { [weak self] in
            guard let self, !self.isCancelled else { return }
            switch interaction {
            case .click:
                self.emit(.click)
            case .keyDown:
                self.scheduleTypingBoundary()
            case .scrollWheel:
                self.scheduleScrollBoundary()
            }
        }
    }

    func cancel() {
        queue.sync {
            isCancelled = true
            typingTimer?.setEventHandler {}
            typingTimer?.cancel()
            typingTimer = nil
            scrollTimer?.setEventHandler {}
            scrollTimer?.cancel()
            scrollTimer = nil
        }
    }

    private func scheduleTypingBoundary() {
        let timer = typingTimer ?? makeTimer(trigger: .typingPause)
        typingTimer = timer
        timer.schedule(deadline: .now() + typingDelay, repeating: .never)
    }

    private func scheduleScrollBoundary() {
        let timer = scrollTimer ?? makeTimer(trigger: .scrollSettled)
        scrollTimer = timer
        timer.schedule(deadline: .now() + scrollDelay, repeating: .never)
    }

    private func makeTimer(trigger: ScreenCaptureTrigger) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [emit] in emit(trigger) }
        timer.resume()
        return timer
    }
}

@MainActor
final class ScreenContextEventMonitor {
    var onTrigger: ((ScreenCaptureTrigger) -> Void)?

    private var globalMonitor: Any?
    private var pasteboardTimer: Timer?
    private var eventCoalescer: ScreenContextEventCoalescer?
    private var launchObserver: (any NSObjectProtocol)?
    private var lastPasteboardChangeCount = NSPasteboard.general.changeCount

    func start() {
        guard globalMonitor == nil else { return }
        if NSApp?.isRunning == true {
            install()
        } else if launchObserver == nil {
            launchObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didFinishLaunchingNotification,
                object: nil,
                queue: .main
            ) { _ in
                DispatchQueue.main.async {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if let token = self.launchObserver {
                            NotificationCenter.default.removeObserver(token)
                            self.launchObserver = nil
                        }
                        if self.globalMonitor == nil { self.install() }
                    }
                }
            }
        }
    }

    private func install() {
        let coalescer = ScreenContextEventCoalescer { [weak self] trigger in
            Task { @MainActor [weak self] in self?.onTrigger?(trigger) }
        }
        eventCoalescer = coalescer
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseUp, .rightMouseUp, .otherMouseUp, .keyDown, .scrollWheel]
        ) { event in
            switch event.type {
            case .keyDown:
                coalescer.receive(.keyDown)
            case .scrollWheel:
                coalescer.receive(.scrollWheel)
            case .leftMouseUp, .rightMouseUp, .otherMouseUp:
                coalescer.receive(.click)
            default:
                break
            }
        }
        lastPasteboardChangeCount = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkPasteboardBoundary() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pasteboardTimer = timer
    }

    func stop() {
        if let launchObserver {
            NotificationCenter.default.removeObserver(launchObserver)
            self.launchObserver = nil
        }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        globalMonitor = nil
        pasteboardTimer?.invalidate()
        pasteboardTimer = nil
        eventCoalescer?.cancel()
        eventCoalescer = nil
    }

    private func checkPasteboardBoundary() {
        let current = NSPasteboard.general.changeCount
        guard current != lastPasteboardChangeCount else { return }
        lastPasteboardChangeCount = current
        onTrigger?(.clipboardChange)
    }
}
