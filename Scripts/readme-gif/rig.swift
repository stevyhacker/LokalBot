// Films one LokalBot UI Test Host window for the README GIF.
//
// The window is captured with ScreenCaptureKit on its own, over a flat fill,
// including the real pointer. It is driven with real HID input events (pointer
// moves, clicks, keystrokes), so what the GIF shows is the app responding to
// input. A take aborts if the keyboard, mouse or trackpad is touched, so a
// person working on the Mac is never fought over the pointer.
//
//   rig take  <shot.json> <out-dir>   record frames + take.json into out-dir
//   rig still <shot.json> <out.png>   place the window and save one frame
//   rig ax    <shot.json>             place the window and print its accessibility tree
//   rig idle  <seconds>               wait until nobody has touched an input device that long
//
// Build: swiftc -O -swift-version 5 rig.swift -o rig
import AppKit
import ApplicationServices
import CoreMedia
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

func die(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("rig: \(message)\n".utf8))
    exit(code)
}

func note(_ message: String) {
    FileHandle.standardError.write(Data("rig: \(message)\n".utf8))
}

// MARK: - Shot file

struct Target: Decodable {
    var at: [Double]?         // window-relative points
    var id: String?           // AXIdentifier
    var label: String?        // exact AXDescription or AXTitle
    var contains: String?     // substring of AXTitle, AXDescription or AXValue
    var role: String?
    var index: Int?           // nth match, default 0
    var offset: [Double]?     // points added to the resolved position
    var anchor: [Double]?     // fraction of the element frame, default centre [0.5, 0.5]
}

struct Action: Decodable {
    var wait: Double?
    var move: Target?
    var click: Target?
    var type: String?
    var key: String?
    var mods: [String]?
    var scroll: Target?
    var dy: Double?
    var duration: Double?
    var cps: Double?
    var mark: String?
    var park: [Double]?       // window-relative; warps the pointer without motion
    var press: Target?        // AXPress without moving the pointer
    var focus: Target?        // give an element keyboard focus without moving the pointer
    var hold: [String]?       // modifier keys held down while `during` runs, e.g. ["control", "option"]
    var during: [Action]?
    var run: [String]?        // a command started in the background, e.g. a voice line; not waited for
}

struct Shot: Decodable {
    var bundle: String
    var size: [Double]                // outer window size, points
    var background: String?           // #RRGGBB fill behind the window; RIG_BACKGROUND overrides
    var margin: Double?               // points captured around the window
    var bottom: Double?               // window bottom this far above the visible screen bottom; default centred
    var below: Double?                // points captured below the window, e.g. LokalBot's dictation overlay
    var settle: Double?               // seconds between placing and recording
    var pre: Double?                  // seconds recorded before the first action
    var post: Double?                 // seconds recorded after the last action
    var idle: Double?                 // seconds of no human input required to start
    var setup: [Action]?              // runs before recording starts
    var park: [Double]?               // window-relative pointer position while recording starts
    var actions: [Action]
    var also: [String]?               // bundle ids whose windows are captured too, e.g. an overlay
    var title: String?                // capture the window whose title contains this; default: the widest
}

func loadShot(_ path: String) -> Shot {
    guard let data = FileManager.default.contents(atPath: path) else { die("cannot read \(path)") }
    do { return try JSONDecoder().decode(Shot.self, from: data) } catch { die("bad shot \(path): \(error)") }
}

func fill(_ shot: Shot) -> String {
    ProcessInfo.processInfo.environment["RIG_BACKGROUND"] ?? shot.background ?? "#FFFFFF"
}

var fills: [String: CGColor] = [:]

func color(_ hex: String) -> CGColor {
    var value: UInt64 = 0
    Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&value)
    return CGColor(srgbRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255,
                   blue: CGFloat(value & 0xff) / 255, alpha: 1)
}

// MARK: - Displays

/// The built-in Retina panel when present (2x pixels), else the main display.
struct Display {
    let id: CGDirectDisplayID
    let bounds: CGRect        // global, top-left origin
    let visible: CGRect       // global, top-left origin, minus menu bar and Dock
    let scale: CGFloat

    static func filming() -> Display {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let screens = NSScreen.screens.map { screen -> Display in
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID
            let v = screen.visibleFrame
            return Display(id: id, bounds: CGDisplayBounds(id),
                           visible: CGRect(x: v.minX, y: primaryHeight - v.maxY, width: v.width, height: v.height),
                           scale: screen.backingScaleFactor)
        }
        return screens.first { CGDisplayIsBuiltin($0.id) != 0 } ?? screens.max { $0.scale < $1.scale }!
    }
}

// MARK: - Accessibility

func axValue<T>(_ element: AXUIElement, _ name: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value as? T
}

func axFrame(_ element: AXUIElement) -> CGRect? {
    var p: CFTypeRef?, s: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &p) == .success,
          AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &s) == .success else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &point)
    AXValueGetValue(s as! AXValue, .cgSize, &size)
    return CGRect(origin: point, size: size)
}

func axSetFrame(_ window: AXUIElement, _ rect: CGRect) {
    var origin = rect.origin, size = rect.size
    AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &origin)!)
    AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
    AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &origin)!)
}

func axChildren(_ element: AXUIElement) -> [AXUIElement] {
    axValue(element, kAXChildrenAttribute) ?? []
}

func axText(_ element: AXUIElement) -> (role: String, id: String, title: String, desc: String, value: String) {
    let value: Any? = axValue(element, kAXValueAttribute)
    return (axValue(element, kAXRoleAttribute) ?? "", axValue(element, "AXIdentifier") ?? "",
            axValue(element, kAXTitleAttribute) ?? "", axValue(element, kAXDescriptionAttribute) ?? "",
            (value as? String) ?? "")
}

func axFind(_ root: AXUIElement, _ target: Target) -> AXUIElement? {
    var queue = [root], matches: [AXUIElement] = [], visited = 0
    while !queue.isEmpty, visited < 40_000 {
        let element = queue.removeFirst()
        visited += 1
        let t = axText(element)
        var ok = true
        if let id = target.id { ok = ok && t.id == id }
        if let label = target.label { ok = ok && (t.desc == label || t.title == label) }
        if let part = target.contains { ok = ok && (t.title.contains(part) || t.desc.contains(part) || t.value.contains(part)) }
        if let role = target.role { ok = ok && t.role == role }
        if ok, target.id != nil || target.label != nil || target.contains != nil || target.role != nil {
            matches.append(element)
            if matches.count > (target.index ?? 0) { return matches.last }
        }
        queue.append(contentsOf: axChildren(element))
    }
    return nil
}

func axDump(_ element: AXUIElement, origin: CGPoint, depth: Int = 0) {
    guard depth < 40 else { return }
    let t = axText(element)
    var line = String(repeating: "  ", count: depth) + t.role
    if !t.id.isEmpty { line += " #\(t.id)" }
    for text in [t.title, t.desc, t.value] where !text.isEmpty { line += " “\(text.prefix(70))”" }
    if let f = axFrame(element) {
        line += String(format: "  [%.0f,%.0f %.0fx%.0f]", f.minX - origin.x, f.minY - origin.y, f.width, f.height)
    }
    print(line)
    for child in axChildren(element) { axDump(child, origin: origin, depth: depth + 1) }
}

// MARK: - The app under film

final class Subject {
    let app: NSRunningApplication
    let element: AXUIElement
    let window: AXUIElement
    var frame: CGRect

    init(bundle: String, title: String? = nil) {
        let deadline = Date().addingTimeInterval(45)
        var found: (NSRunningApplication, AXUIElement, AXUIElement)?
        while found == nil, Date() < deadline {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first {
                let element = AXUIElementCreateApplication(app.processIdentifier)
                var windows: [AXUIElement] = axValue(element, kAXWindowsAttribute) ?? []
                if let title {
                    windows = windows.filter { (axValue($0, kAXTitleAttribute) as String? ?? "").contains(title) }
                }
                if let window = windows.max(by: { (axFrame($0)?.width ?? 0) < (axFrame($1)?.width ?? 0) }) {
                    found = (app, element, window)
                    break
                }
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        guard let found else { die("no window from \(bundle)") }
        (app, element, window) = found
        frame = axFrame(window) ?? .zero
    }

    func place(size: [Double], on display: Display, bottom: Double? = nil) {
        let w = size[0], h = size[1]
        let y = bottom.map { display.visible.maxY - $0 - h } ?? display.visible.midY - h / 2
        let rect = CGRect(x: (display.visible.midX - w / 2).rounded(), y: y.rounded(), width: w, height: h)
        front()
        axSetFrame(window, rect)
        Thread.sleep(forTimeInterval: 0.3)
        frame = axFrame(window) ?? rect
        if abs(frame.width - w) > 1 || abs(frame.height - h) > 1 {
            note("window settled at \(frame.size) instead of \(w)x\(h)")
        }
    }

    func front() {
        AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
    }

    /// Global point for a target.
    func point(_ target: Target) -> CGPoint {
        var p: CGPoint
        if let at = target.at {
            p = CGPoint(x: frame.minX + at[0], y: frame.minY + at[1])
        } else {
            guard let element = axFind(window, target), let f = axFrame(element) else {
                die("no element for \(target)")
            }
            let anchor = target.anchor ?? [0.5, 0.5]
            p = CGPoint(x: f.minX + f.width * anchor[0], y: f.minY + f.height * anchor[1])
        }
        if let offset = target.offset { p.x += offset[0]; p.y += offset[1] }
        return p
    }
}

// MARK: - Input

let anyInput = CGEventType(rawValue: ~0)!
/// Seconds since the HID system last saw input. Keystrokes and clicks this
/// tool posts reset it too; pointer moves are warps and do not.
func hidIdle() -> Double { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput) }

/// When this tool last posted an event.
var lastPost = Date.distantPast

/// True when input arrived after `start` that this tool did not post.
func touchedSince(_ start: Date) -> Bool {
    let quiet = min(Date().timeIntervalSince(start), Date().timeIntervalSince(lastPost))
    return hidIdle() + 0.05 < quiet
}

let source = CGEventSource(stateID: .privateState)

func pointer() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

func post(_ event: CGEvent?) {
    event?.post(tap: .cgSessionEventTap)
    lastPost = Date()
}

/// Moves the visible pointer and tells the app under it.
func pointTo(_ p: CGPoint) {
    CGWarpMouseCursorPosition(p)
    post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left))
}

func glide(to end: CGPoint, duration: Double) {
    let start = pointer()
    let steps = max(1, Int(duration * 120))
    for step in 1...steps {
        let t = Double(step) / Double(steps)
        let e = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        let p = CGPoint(x: start.x + (end.x - start.x) * e, y: start.y + (end.y - start.y) * e)
        pointTo(p)
        Thread.sleep(forTimeInterval: duration / Double(steps))
    }
}

func click(at p: CGPoint) {
    pointTo(p)
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
        event?.setIntegerValueField(.mouseEventClickState, value: 1)
        post(event)
        Thread.sleep(forTimeInterval: type == .leftMouseDown ? 0.07 : 0.02)
    }
}

let keyCodes: [Character: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
    "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
    "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37,
    "j": 38, "'": 39, "k": 40, ";": 41, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, " ": 49,
]
let namedKeys: [String: CGKeyCode] = [
    "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53,
    "left": 123, "right": 124, "down": 125, "up": 126,
]

func flags(_ mods: [String]) -> CGEventFlags {
    var f: CGEventFlags = []
    if mods.contains("cmd") { f.insert(.maskCommand) }
    if mods.contains("shift") { f.insert(.maskShift) }
    if mods.contains("option") { f.insert(.maskAlternate) }
    if mods.contains("control") { f.insert(.maskControl) }
    return f
}

func key(_ code: CGKeyCode, text: String?, flags f: CGEventFlags) {
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
        event?.flags = f
        if let text {
            let units = Array(text.utf16)
            event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        }
        post(event)
        Thread.sleep(forTimeInterval: 0.012)
    }
}

let modifierKeys: [String: (code: CGKeyCode, flag: CGEventFlags)] = [
    "option": (58, .maskAlternate), "control": (59, .maskControl), "shift": (56, .maskShift), "cmd": (55, .maskCommand),
]

/// Presses and holds keys in order, e.g. ["option", "space"], and returns the
/// release. Push-to-talk shortcuts need the key held, not tapped.
func holdDown(_ names: [String]) -> () -> Void {
    var held: CGEventFlags = []
    var keys: [CGKeyCode] = []
    for name in names {
        if let modifier = modifierKeys[name] {
            held.insert(modifier.flag)
            let event = CGEvent(keyboardEventSource: source, virtualKey: modifier.code, keyDown: true)
            event?.type = .flagsChanged
            event?.flags = held
            post(event)
        } else if let code = namedKeys[name] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
            event?.flags = held
            post(event)
            keys.append(code)
        } else {
            die("unknown key \(name)")
        }
        Thread.sleep(forTimeInterval: 0.03)
    }
    return {
        for code in keys.reversed() {
            let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
            event?.flags = held
            post(event)
            Thread.sleep(forTimeInterval: 0.03)
        }
        for name in names.reversed() {
            guard let modifier = modifierKeys[name] else { continue }
            held.remove(modifier.flag)
            let event = CGEvent(keyboardEventSource: source, virtualKey: modifier.code, keyDown: false)
            event?.type = .flagsChanged
            event?.flags = held
            post(event)
            Thread.sleep(forTimeInterval: 0.03)
        }
    }
}

/// Deterministic jitter so retakes type with the same rhythm.
var rhythm: UInt64 = 0x9E3779B97F4A7C15
func jitter() -> Double {
    rhythm = rhythm &* 6364136223846793005 &+ 1442695040888963407
    return 0.75 + Double((rhythm >> 33) % 1000) / 1000 * 0.5
}

// MARK: - Capture

final class Capture: NSObject, SCStreamOutput {
    let dir: URL
    private let encode = DispatchQueue(label: "rig.encode", qos: .userInitiated, attributes: .concurrent)
    private let group = DispatchGroup()
    private let gate = DispatchSemaphore(value: 10)
    private let lock = NSLock()
    private(set) var stamps: [[Double]] = []
    private(set) var origin: Double?
    let started = DispatchSemaphore(value: 0)

    init(dir: URL) { self.dir = dir }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid,
              let infos = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = infos.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(buffer), let image = Self.copyImage(pixels) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
        lock.lock()
        let first = origin == nil
        if first { origin = pts }
        let index = stamps.count
        stamps.append([Double(index), pts - origin!])
        lock.unlock()
        if first {
            let lag = CMClockGetTime(CMClockGetHostTimeClock()).seconds - pts
            if abs(lag) > 0.5 { note(String(format: "frame clock is %.2fs from host clock", lag)) }
            started.signal()
        }
        gate.wait()
        group.enter()
        let url = dir.appendingPathComponent(String(format: "%05d.png", index))
        encode.async { [gate, group] in
            if let out = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(out, image, nil)
                CGImageDestinationFinalize(out)
            }
            gate.signal()
            group.leave()
        }
    }

    /// Copies the pooled IOSurface so the stream can reuse it immediately.
    static func copyImage(_ pixels: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return nil }
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        let data = Data(bytes: base, count: stride * height) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    func now() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds - (origin ?? 0) }

    func drain() { group.wait() }
}

/// The display with every window left out except the subject's and those of
/// the `also` apps. Windows are listed when capture starts, so an overlay app
/// must already be running then; panels it opens later belong to no excluded
/// window and are captured. Naming the subject's app as the shared content
/// instead makes macOS badge its windows with the purple "window is being
/// shared" capsule in place of the window controls.
func filter(for subject: Subject, display: Display, also: [String]) async -> SCContentFilter {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let scDisplay = content.displays.first(where: { $0.displayID == display.id }) else { die("display not shareable") }
        let pid = subject.app.processIdentifier
        guard content.windows.contains(where: { $0.owningApplication?.processID == pid }) else { die("app not shareable") }
        let kept = Set([pid] + also.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
            .map(\.processIdentifier))
        let others = content.windows.filter { window in
            guard let owner = window.owningApplication?.processID else { return true }
            return !kept.contains(owner)
        }
        return SCContentFilter(display: scDisplay, excludingWindows: others)
    } catch {
        die("screen capture unavailable: \(error)")
    }
}

func configuration(for rect: CGRect, display: Display, background: String) -> SCStreamConfiguration {
    let config = SCStreamConfiguration()
    config.sourceRect = rect.offsetBy(dx: -display.bounds.minX, dy: -display.bounds.minY)
    config.width = Int(rect.width * display.scale)
    config.height = Int(rect.height * display.scale)
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.colorSpaceName = CGColorSpace.sRGB
    // SCStreamConfiguration holds backgroundColor without retaining it.
    fills[background] = fills[background] ?? color(background)
    config.backgroundColor = fills[background]!
    config.showsCursor = true
    config.ignoreShadowsDisplay = true
    config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
    config.queueDepth = 8
    return config
}

// MARK: - Commands

func captureRect(_ subject: Subject, _ shot: Shot) -> CGRect {
    var rect = subject.frame.insetBy(dx: -(shot.margin ?? 0), dy: -(shot.margin ?? 0))
    if let below = shot.below { rect.size.height += below }
    return rect
}

/// Places the window, runs the shot's setup, places it again (setup can change
/// its minimum size), and leaves it frontmost and settled.
func prepare(_ shot: Shot) -> (Subject, Display) {
    guard AXIsProcessTrusted() else { die("Accessibility permission is required") }
    guard CGPreflightScreenCaptureAccess() else { die("Screen Recording permission is required") }
    let display = Display.filming()
    let subject = Subject(bundle: shot.bundle, title: shot.title)
    subject.place(size: shot.size, on: display, bottom: shot.bottom)
    if let setup = shot.setup, !setup.isEmpty {
        var log: [[String: Any]] = []
        run(setup, subject: subject, capture: nil, rect: .zero, log: &log, startedAt: Date())
        pause(0.6)
        subject.place(size: shot.size, on: display, bottom: shot.bottom)
    }
    pause(shot.settle ?? 1.2)
    subject.front()
    pause(0.3)
    return (subject, display)
}

func run(_ actions: [Action], subject: Subject, capture: Capture?, rect: CGRect,
         log: inout [[String: Any]], startedAt: Date) {
    func record(_ kind: String, _ p: CGPoint? = nil, _ extra: [String: Any] = [:]) {
        guard let capture else { return }
        var entry: [String: Any] = ["t": (capture.now() * 1000).rounded() / 1000, "kind": kind]
        if let p { entry["x"] = p.x - rect.minX; entry["y"] = p.y - rect.minY }
        entry.merge(extra) { a, _ in a }
        log.append(entry)
    }
    func guardHuman() {
        guard capture != nil else { return }
        if touchedSince(startedAt) { die("human input during the take; aborted", code: 3) }
        if !subject.isFrontmost { die("another app came to the front; aborted", code: 3) }
    }
    for action in actions {
        guardHuman()
        if let seconds = action.wait {
            Thread.sleep(forTimeInterval: seconds)
        } else if let park = action.park {
            CGWarpMouseCursorPosition(CGPoint(x: subject.frame.minX + park[0], y: subject.frame.minY + park[1]))
            CGAssociateMouseAndMouseCursorPosition(1)
        } else if let target = action.move {
            let p = subject.point(target)
            record("move", p)
            glide(to: p, duration: action.duration ?? 0.55)
        } else if let target = action.click {
            let p = subject.point(target)
            glide(to: p, duration: action.duration ?? 0.55)
            Thread.sleep(forTimeInterval: 0.08)
            record("click", p)
            click(at: p)
        } else if let text = action.type {
            record("type", nil, ["text": text])
            let cps = action.cps ?? 9
            for character in text {
                guardHuman()
                let lower = Character(character.lowercased())
                let shifted = character.isUppercase || "?!:\"$%&*()_+".contains(character)
                key(keyCodes[lower] ?? 0, text: String(character), flags: shifted ? .maskShift : [])
                Thread.sleep(forTimeInterval: jitter() / cps)
            }
        } else if let name = action.key {
            guard let code = namedKeys[name] else { die("unknown key \(name)") }
            record("key", nil, ["key": name])
            key(code, text: nil, flags: flags(action.mods ?? []))
        } else if let target = action.scroll {
            let p = subject.point(target)
            glide(to: p, duration: action.duration ?? 0.4)
            record("scroll", p, ["dy": action.dy ?? 0])
            let steps = 24, total = action.dy ?? -200
            for _ in 0..<steps {
                post(CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1,
                             wheel1: Int32(total / Double(steps)), wheel2: 0, wheel3: 0))
                Thread.sleep(forTimeInterval: 1.0 / 60)
            }
        } else if let target = action.press {
            guard let element = axFind(subject.window, target) else { die("no element for \(target)") }
            AXUIElementPerformAction(element, kAXPressAction as CFString)
        } else if let target = action.focus {
            guard let element = axFind(subject.window, target) else { die("no element for \(target)") }
            AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        } else if let names = action.hold {
            record("hold", nil, ["keys": names])
            let release = holdDown(names)
            run(action.during ?? [], subject: subject, capture: capture, rect: rect, log: &log, startedAt: startedAt)
            release()
            record("release", nil, ["keys": names])
        } else if let command = action.run, let tool = command.first {
            record("run", nil, ["command": command.joined(separator: " ")])
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = Array(command.dropFirst())
            do { try process.run() } catch { die("cannot run \(tool): \(error)") }
        } else if let mark = action.mark {
            record("mark", nil, ["name": mark])
        }
    }
}

func pause(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

func waitForHumanIdle(_ seconds: Double) {
    let deadline = Date().addingTimeInterval(900)
    while hidIdle() < seconds {
        guard Date() < deadline else { die("no idle window for 15 minutes", code: 4) }
        pause(0.5)
    }
}

func firstFrame(_ capture: Capture) -> Bool { capture.started.wait(timeout: .now() + 5) == .success }

func take(_ shot: Shot, out: URL) async {
    waitForHumanIdle(shot.idle ?? 4)
    let (subject, display) = prepare(shot)
    var log: [[String: Any]] = []
    let rect = captureRect(subject, shot)
    if let park = shot.park {
        CGWarpMouseCursorPosition(CGPoint(x: subject.frame.minX + park[0], y: subject.frame.minY + park[1]))
        CGAssociateMouseAndMouseCursorPosition(1)
    }
    let frames = out.appendingPathComponent("frames")
    let capture = Capture(dir: frames)
    let stream = SCStream(filter: await filter(for: subject, display: display, also: shot.also ?? []),
                          configuration: configuration(for: rect, display: display, background: fill(shot)),
                          delegate: nil)
    do {
        try? FileManager.default.removeItem(at: frames)
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        try stream.addStreamOutput(capture, type: .screen, sampleHandlerQueue: DispatchQueue(label: "rig.capture"))
        try await stream.startCapture()
    } catch {
        die("capture failed to start: \(error)")
    }
    let startedAt = Date()
    guard firstFrame(capture) else { die("no frames arrived") }
    pause(shot.pre ?? 0.6)
    run(shot.actions, subject: subject, capture: capture, rect: rect, log: &log, startedAt: startedAt)
    pause(shot.post ?? 1.0)
    let end = capture.now()
    try? await stream.stopCapture()
    capture.drain()
    if touchedSince(startedAt) { die("human input during the take; aborted", code: 3) }
    let meta: [String: Any] = [
        "rect": [rect.minX, rect.minY, rect.width, rect.height],
        "scale": display.scale, "background": fill(shot), "end": end,
        "frames": capture.stamps, "events": log,
    ]
    do {
        let json = try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: out.appendingPathComponent("take.json"))
    } catch {
        die("cannot write take.json: \(error)")
    }
    print(String(format: "take: %d frames, %.2fs, %@", capture.stamps.count, end, out.path))
}

func still(_ shot: Shot, out: URL) async {
    let (subject, display) = prepare(shot)
    let rect = captureRect(subject, shot)
    do {
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: await filter(for: subject, display: display, also: shot.also ?? []),
            configuration: configuration(for: rect, display: display, background: fill(shot)))
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            die("cannot write \(out.path)")
        }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        print("still: \(image.width)x\(image.height) \(out.path)")
    } catch {
        die("screenshot failed: \(error)")
    }
}

let usage = "usage: rig take|still|ax <shot.json> [out] | rig idle <seconds>"
let args = CommandLine.arguments
guard args.count >= 3 else { die(usage) }
if args[1] == "idle", let seconds = Double(args[2]) {
    waitForHumanIdle(seconds)
    exit(0)
}
let shot = loadShot(args[2])
switch args[1] {
case "take" where args.count == 4:
    await take(shot, out: URL(fileURLWithPath: args[3]))
case "still" where args.count == 4:
    await still(shot, out: URL(fileURLWithPath: args[3]))
case "ax":
    let (subject, _) = prepare(shot)
    axDump(subject.window, origin: subject.frame.origin)
default:
    die(usage)
}
