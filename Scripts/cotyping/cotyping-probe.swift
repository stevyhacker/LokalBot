import AppKit
import Foundation
import ImageIO

enum ProbeCaptureContract {
    static func arguments(rectString: String, imageURL: URL) -> [String] {
        ["-x", "-R", rectString, imageURL.path]
    }

    static func hasExpectedDimensions(
        width: Int,
        height: Int,
        captureRect: NSRect,
        backingScale: CGFloat
    ) -> Bool {
        [CGFloat(1), backingScale].contains {
            width == Int(captureRect.width * $0) && height == Int(captureRect.height * $0)
        }
    }

    static func selfTest() -> Bool {
        let rect = NSRect(x: 10, y: 20, width: 640, height: 480)
        let output = URL(fileURLWithPath: "/tmp/bounded-probe.png")
        return arguments(rectString: "10,20,640,480", imageURL: output)
            == ["-x", "-R", "10,20,640,480", output.path]
            && hasExpectedDimensions(width: 640, height: 480,
                                     captureRect: rect, backingScale: 2)
            && hasExpectedDimensions(width: 1280, height: 960,
                                     captureRect: rect, backingScale: 2)
            && !hasExpectedDimensions(width: 1920, height: 1080,
                                      captureRect: rect, backingScale: 2)
    }
}

struct ProbeConfig {
    enum InputMode: String {
        case direct
        case events
    }

    var prompt: String = ""
    var slug: String = "probe"
    var outputDirectory: URL = URL(fileURLWithPath: "/tmp/cotyping-probe")
    var typeDelay: TimeInterval = 0.025
    var waitSeconds: TimeInterval = 5
    var inputMode: InputMode = .direct

    init(arguments: [String]) {
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            let nextIndex = index + 1
            switch argument {
            case "--prompt" where nextIndex < arguments.count:
                prompt = arguments[nextIndex]
                index += 2
            case "--slug" where nextIndex < arguments.count:
                slug = arguments[nextIndex]
                index += 2
            case "--output-dir" where nextIndex < arguments.count:
                outputDirectory = URL(fileURLWithPath: arguments[nextIndex])
                index += 2
            case "--type-delay" where nextIndex < arguments.count:
                typeDelay = TimeInterval(arguments[nextIndex]) ?? typeDelay
                index += 2
            case "--wait" where nextIndex < arguments.count:
                waitSeconds = TimeInterval(arguments[nextIndex]) ?? waitSeconds
                index += 2
            case "--input-mode" where nextIndex < arguments.count:
                inputMode = InputMode(rawValue: arguments[nextIndex]) ?? inputMode
                index += 2
            default:
                fputs("Unknown or incomplete argument: \(argument)\n", stderr)
                exit(64)
            }
        }

        guard !prompt.isEmpty else {
            fputs("--prompt is required\n", stderr)
            exit(64)
        }
    }
}

final class ProbeAppDelegate: NSObject, NSApplicationDelegate {
    private let config: ProbeConfig
    private let textView = NSTextView(frame: .zero)
    private var window: NSWindow?
    private(set) var exitStatus: Int32 = EXIT_SUCCESS

    init(config: ProbeConfig) {
        self.config = config
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try FileManager.default.createDirectory(
                at: config.outputDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            fputs("Could not create output directory: \(error)\n", stderr)
            finish(status: EXIT_FAILURE)
            return
        }

        let windowFrame = NSRect(x: 260, y: 260, width: 900, height: 360)
        let window = NSWindow(
            contentRect: windowFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Cotyping Probe - \(config.slug)"
        window.isReleasedWhenClosed = false

        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.font = NSFont.systemFont(ofSize: 28)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.string = ""

        let scrollView = NSScrollView(frame: window.contentView?.bounds ?? .zero)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView
        window.contentView = scrollView

        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(textView)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            self.typeNextCharacter(at: self.config.prompt.startIndex)
        }
    }

    private func typeNextCharacter(at index: String.Index) {
        guard index < config.prompt.endIndex else {
            DispatchQueue.main.asyncAfter(deadline: .now() + config.waitSeconds) {
                self.captureAndFinish()
            }
            return
        }

        let character = String(config.prompt[index])
        switch config.inputMode {
        case .direct:
            textView.insertText(character, replacementRange: NSRange(location: textView.string.count, length: 0))
            textView.scrollRangeToVisible(NSRange(location: textView.string.count, length: 0))
        case .events:
            postKeyboardCharacter(character)
        }
        let nextIndex = config.prompt.index(after: index)
        DispatchQueue.main.asyncAfter(deadline: .now() + config.typeDelay) {
            self.typeNextCharacter(at: nextIndex)
        }
    }

    private func captureAndFinish() {
        writeTextFile(name: "\(config.slug).txt", contents: config.prompt)
        writeTextFile(name: "\(config.slug).document.txt", contents: textView.string)

        guard let captureRect = captureRect() else {
            fputs("Could not determine capture rect\n", stderr)
            finish(status: EXIT_FAILURE)
            return
        }

        let rectString = "\(Int(captureRect.origin.x)),\(Int(captureRect.origin.y)),\(Int(captureRect.width)),\(Int(captureRect.height))"
        writeTextFile(name: "\(config.slug).rect", contents: rectString)

        let imageURL = config.outputDirectory.appendingPathComponent("\(config.slug).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ProbeCaptureContract.arguments(
            rectString: rectString, imageURL: imageURL)
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                throw NSError(domain: "ProbeCapture", code: Int(process.terminationStatus))
            }
            guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else {
                throw NSError(domain: "ProbeCapture", code: 1)
            }
            let scale = window?.screen?.backingScaleFactor ?? 1
            guard ProbeCaptureContract.hasExpectedDimensions(
                width: width, height: height, captureRect: captureRect,
                backingScale: scale
            ) else { throw NSError(domain: "ProbeCapture", code: 2) }
        } catch {
            try? FileManager.default.removeItem(at: imageURL)
            fputs("Could not run screencapture: \(error)\n", stderr)
            finish(status: EXIT_FAILURE)
            return
        }

        print(config.outputDirectory.path)
        finish(status: EXIT_SUCCESS)
    }

    private func captureRect() -> NSRect? {
        guard let window else { return nil }
        let frame = window.frame
        let screen = window.screen ?? NSScreen.main
        guard let screen else { return nil }

        let region = frame.insetBy(dx: -120, dy: -120).intersection(screen.frame).integral
        guard !region.isEmpty, let primary = NSScreen.screens.first else { return nil }
        // screencapture uses global top-left coordinates, including displays
        // whose origin is negative or above the primary display.
        return NSRect(x: region.minX, y: primary.frame.maxY - region.maxY,
                      width: region.width, height: region.height)
    }

    private func writeTextFile(name: String, contents: String) {
        let url = config.outputDirectory.appendingPathComponent(name)
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            fputs("Could not write \(url.path): \(error)\n", stderr)
        }
    }

    private func finish(status: Int32) {
        exitStatus = status
        NSApp.terminate(nil)
    }

    private func postKeyboardCharacter(_ character: String) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        var utf16 = Array(character.utf16)
        guard !utf16.isEmpty else { return }

        let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        down?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        down?.post(tap: .cghidEventTap)

        let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        up?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        up?.post(tap: .cghidEventTap)
    }
}

if Array(CommandLine.arguments.dropFirst()) == ["--self-test-capture-contract"] {
    guard ProbeCaptureContract.selfTest() else {
        fputs("Cotyping probe capture contract failed\n", stderr)
        exit(EXIT_FAILURE)
    }
    print("Cotyping probe capture contract passed")
    exit(EXIT_SUCCESS)
}

let config = ProbeConfig(arguments: CommandLine.arguments)
let app = NSApplication.shared
let delegate = ProbeAppDelegate(config: config)
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
exit(delegate.exitStatus)
