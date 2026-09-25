import AppKit
import ApplicationServices
import Foundation

struct ScreenAccessibilitySnapshot: Equatable, Sendable {
    var text: String
    var sourceURL: String?
    var documentName: String?
    var focusedSecureField: Bool?
    var windowTitle: String?
    var windowFrame: CGRect?
    var hasWebContent: Bool = false

    func privacyObservation(appName: String, bundleIdentifier: String?) -> ScreenContextPrivacy.Observation {
        .init(appName: appName, bundleIdentifier: bundleIdentifier,
              windowTitle: windowTitle, sourceURL: sourceURL,
              focusedSecureField: focusedSecureField, hasWebContent: hasWebContent)
    }
}

struct ScreenAccessibilityCaptureResult: Equatable, Sendable {
    var snapshot: ScreenAccessibilitySnapshot?
    var timedOut: Bool

    static let timeout = Self(snapshot: nil, timedOut: true)
}

enum ScreenVisibleTextPolicy {
    /// Whole AXValue/selected-text/help strings can contain a complete hidden
    /// document. Only visible-range text or fully visible static labels qualify.
    static func text(role: String?, frame: CGRect?, viewport: CGRect?, hidden: Bool,
                     title: String?, visibleRangeText: String?, staticValue: String?) -> [String] {
        guard !hidden, let frame, let viewport,
              !frame.isEmpty, !frame.isNull,
              frame.intersects(viewport) else { return [] }
        var result: [String] = []
        if let visibleRangeText { result.append(visibleRangeText) }
        let labels: Set<String> = ["AXStaticText", "AXButton", "AXCheckBox", "AXRadioButton", "AXMenuItem", "AXLink", "AXWindow"]
        if let role, labels.contains(role), viewport.contains(frame) {
            if let title { result.append(title) }
            if role == "AXStaticText", let staticValue { result.append(staticValue) }
        }
        return result
    }
}

/// A bounded, single-flight reader for visible Accessibility text. Cross-process
/// AX calls never run on the main actor, and a wedged target can occupy only one
/// worker rather than creating an unbounded queue of blocked snapshots.
final class ScreenAccessibilityReader: @unchecked Sendable {
    typealias Resolver = @Sendable (pid_t) -> ScreenAccessibilitySnapshot?

    static let shared = ScreenAccessibilityReader()
    /// Activity-only sampling inspects privacy metadata, never document text.
    static let metadataOnly = ScreenAccessibilityReader {
        resolve(processID: $0, includeText: false)
    }
    static let defaultDeadlineMilliseconds = 180
    static let perElementMessagingTimeout: Float = 0.025

    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<ScreenAccessibilityCaptureResult, Never>
    }

    private struct Work {
        let id: UInt64
        let processID: pid_t
        var waiters: [UInt64: Waiter]
    }

    private let stateQueue = DispatchQueue(label: "me.dotenv.LokalBot.screen-ax-state")
    private let workerQueue = DispatchQueue(
        label: "me.dotenv.LokalBot.screen-ax-worker",
        qos: .utility)
    private let deadlineMilliseconds: Int
    private let resolver: Resolver
    private var nextIdentifier: UInt64 = 0
    private var active: Work?

    init(
        deadlineMilliseconds: Int = defaultDeadlineMilliseconds,
        resolver: @escaping Resolver = { processID in
            ScreenAccessibilityReader.resolve(processID: processID)
        }
    ) {
        self.deadlineMilliseconds = max(1, deadlineMilliseconds)
        self.resolver = resolver
    }

    func capture(processID: pid_t) async -> ScreenAccessibilityCaptureResult {
        guard processID > 0, !Self.isOwnProcess(processID) else {
            return .init(snapshot: nil, timedOut: false)
        }
        return await withCheckedContinuation { continuation in
            stateQueue.async { [self] in
                nextIdentifier &+= 1
                let waiter = Waiter(id: nextIdentifier, continuation: continuation)
                enqueue(waiter: waiter, processID: processID)
                stateQueue.asyncAfter(
                    deadline: .now() + .milliseconds(deadlineMilliseconds)
                ) { [weak self] in
                    self?.expire(waiterID: waiter.id)
                }
            }
        }
    }

    private func enqueue(waiter: Waiter, processID: pid_t) {
        if var active {
            guard active.processID == processID else {
                waiter.continuation.resume(returning: .timeout)
                return
            }
            active.waiters[waiter.id] = waiter
            self.active = active
            return
        }

        nextIdentifier &+= 1
        let work = Work(
            id: nextIdentifier,
            processID: processID,
            waiters: [waiter.id: waiter])
        active = work
        workerQueue.async { [weak self] in
            guard let self else { return }
            let snapshot = resolver(processID)
            stateQueue.async { [weak self] in
                self?.finish(workID: work.id, snapshot: snapshot)
            }
        }
    }

    private func expire(waiterID: UInt64) {
        guard var active, let waiter = active.waiters.removeValue(forKey: waiterID) else { return }
        self.active = active
        waiter.continuation.resume(returning: .timeout)
    }

    private func finish(workID: UInt64, snapshot: ScreenAccessibilitySnapshot?) {
        guard let completed = active, completed.id == workID else { return }
        active = nil
        let result = ScreenAccessibilityCaptureResult(snapshot: snapshot, timedOut: false)
        for waiter in completed.waiters.values {
            waiter.continuation.resume(returning: result)
        }
    }

    /// macOS answers an app's accessibility queries about itself in-process,
    /// on the calling thread. From these background workers that walks
    /// LokalBot's SwiftUI hierarchy off the main actor, which traps. LokalBot
    /// never records its own window as screen context anyway.
    static func isOwnProcess(_ processID: pid_t) -> Bool {
        processID == ProcessInfo.processInfo.processIdentifier
    }

    static func resolve(processID: pid_t, includeText: Bool = true) -> ScreenAccessibilitySnapshot? {
        guard AXIsProcessTrusted(), processID > 0, !isOwnProcess(processID) else { return nil }
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, perElementMessagingTimeout)
        guard let window = elementAttribute(app, kAXFocusedWindowAttribute as String) else {
            return nil
        }
        let windowTitle = textualAttribute(window, kAXTitleAttribute as String)
        let windowFrame = frame(of: window)

        let focused = elementAttribute(app, kAXFocusedUIElementAttribute as String)
        let focusedSecureField = focused.flatMap(secureFieldStatus)

        var queue: [(element: AXUIElement, viewport: CGRect?)] = [(window, windowFrame)]
        var visited = Set<CFHashCode>()
        var parts: [String] = []
        var seenText = Set<String>()
        var sourceURLs = Set<String>()
        let document = textualValue(attribute(window, kAXDocumentAttribute as String))
        if let document, ScreenContextPrivacy.sanitizedURL(document) != nil {
            sourceURLs.insert(document)
        }
        var hasWebContent = false
        var hasUnknownWebURL = false
        var totalCharacters = 0
        let started = ContinuousClock.now
        let maximumDuration = Duration.milliseconds(140)
        let maximumNodes = 320
        let maximumCharacters = 24_000

        while !queue.isEmpty,
              visited.count < maximumNodes,
              totalCharacters < maximumCharacters,
              started.duration(to: .now) < maximumDuration {
            let next = queue.removeFirst()
            let element = next.element
            let identity = CFHash(element)
            guard visited.insert(identity).inserted else { continue }
            AXUIElementSetMessagingTimeout(element, perElementMessagingTimeout)

            let role = textualAttribute(element, kAXRoleAttribute as String)
            let secure = includeText ? secureFieldStatus(element) : nil
            let elementFrame = includeText ? frame(of: element) : nil
            let hidden = attribute(element, "AXHidden") as? Bool == true
            if includeText, secure == false {
                let visibleText = ScreenVisibleTextPolicy.text(
                    role: role, frame: elementFrame, viewport: next.viewport, hidden: hidden,
                    title: textualAttribute(element, kAXTitleAttribute as String),
                    visibleRangeText: Self.visibleText(of: element),
                    staticValue: role == "AXStaticText" ? textualAttribute(element, kAXValueAttribute as String) : nil)
                for text in visibleText {
                    append(
                        text,
                        parts: &parts,
                        seen: &seenText,
                        totalCharacters: &totalCharacters,
                        maximumCharacters: maximumCharacters)
                }
            }

            if role == "AXWebArea" {
                hasWebContent = true
                // A link URL is not the document's origin. Only a web area's
                // own URL (or the window document) can establish that origin.
                if let url = urlString(attribute(element, kAXURLAttribute as String)),
                   ScreenContextPrivacy.sanitizedURL(url) != nil {
                    sourceURLs.insert(url)
                } else {
                    hasUnknownWebURL = true
                }
            }
            if !hidden, let children = (attribute(element, kAXVisibleChildrenAttribute as String)
                ?? attribute(element, kAXChildrenAttribute as String)) as? [AXUIElement] {
                let clipsChildren = ["AXScrollArea", "AXWebArea", "AXWindow"].contains(role ?? "")
                let viewport = clipsChildren
                    ? elementFrame.flatMap { next.viewport?.intersection($0) } : next.viewport
                queue.append(contentsOf: children.prefix(80).map { ($0, viewport) })
            }
        }

        // AX calls are asynchronous with respect to the other application.
        // Never attach one window's text to a different focused window.
        guard let currentWindow = elementAttribute(app, kAXFocusedWindowAttribute as String),
              CFEqual(window, currentWindow),
              textualAttribute(currentWindow, kAXTitleAttribute as String) == windowTitle,
              frame(of: currentWindow) == windowFrame,
              elementAttribute(app, kAXFocusedUIElementAttribute as String)
                .flatMap(secureFieldStatus) == focusedSecureField else { return nil }
        let text = parts.joined(separator: "\n")
        return ScreenAccessibilitySnapshot(
            text: text,
            sourceURL: !hasUnknownWebURL && sourceURLs.count == 1 ? sourceURLs.first : nil,
            documentName: ScreenContextPrivacy.sanitizedDocumentName(document),
            focusedSecureField: focusedSecureField,
            windowTitle: windowTitle,
            windowFrame: windowFrame,
            hasWebContent: hasWebContent)
    }

    private static func append(
        _ raw: String,
        parts: inout [String],
        seen: inout Set<String>,
        totalCharacters: inout Int,
        maximumCharacters: Int
    ) {
        let value = raw
            .replacingOccurrences(of: "\u{0000}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 8_000, seen.insert(value).inserted else { return }
        let remaining = maximumCharacters - totalCharacters
        guard remaining > 0 else { return }
        let clipped = String(value.prefix(remaining))
        parts.append(clipped)
        totalCharacters += clipped.count
    }

    private static func visibleText(of element: AXUIElement) -> String? {
        guard let rawRange = attribute(element, kAXVisibleCharacterRangeAttribute as String),
              CFGetTypeID(rawRange) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rawRange as! AXValue, .cfRange, &range),
              range.location >= 0, range.length > 0 else { return nil }
        range.length = min(range.length, 24_000)
        guard let bounded = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, bounded, &value) == .success
        else { return nil }
        return textualValue(value)
    }

    private static func secureFieldStatus(_ element: AXUIElement) -> Bool? {
        guard let role = textualAttribute(element, kAXRoleAttribute as String), !role.isEmpty else {
            return nil
        }
        var rawSubrole: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element, kAXSubroleAttribute as CFString, &rawSubrole)
        guard status == .success || status == .attributeUnsupported || status == .noValue else {
            return nil
        }
        let subrole = textualValue(rawSubrole)
        return CotypingSecureFieldDetector.isSecure(
            role: role,
            subrole: subrole,
            roleDescription: textualAttribute(element, kAXRoleDescriptionAttribute as String),
            title: textualAttribute(element, kAXTitleAttribute as String),
            descriptionLabel: textualAttribute(element, kAXDescriptionAttribute as String))
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let rawPosition = attribute(element, kAXPositionAttribute as String),
              let rawSize = attribute(element, kAXSizeAttribute as String),
              CFGetTypeID(rawPosition) == AXValueGetTypeID(),
              CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(rawPosition as! AXValue, .cgPoint, &position),
              AXValueGetValue(rawSize as! AXValue, .cgSize, &size),
              position.x.isFinite, position.y.isFinite,
              size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let raw = attribute(element, name),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    private static func textualAttribute(_ element: AXUIElement, _ name: String) -> String? {
        textualValue(attribute(element, name))
    }

    private static func textualValue(_ value: CFTypeRef?) -> String? {
        switch value {
        case let string as String:
            return string
        case let attributed as NSAttributedString:
            return attributed.string
        case let url as URL:
            return url.absoluteString
        default:
            return nil
        }
    }

    private static func urlString(_ value: CFTypeRef?) -> String? {
        switch value {
        case let url as URL: url.absoluteString
        case let string as String: string
        default: nil
        }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            name as CFString,
            &value) == .success else { return nil }
        return value
    }
}
