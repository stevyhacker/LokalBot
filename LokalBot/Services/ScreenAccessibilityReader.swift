import AppKit
import ApplicationServices
import Foundation

struct ScreenAccessibilitySnapshot: Codable, Equatable, Sendable {
    var text: String
    var sourceURL: String?
    var documentName: String?
    var focusedSecureField: Bool?
    var windowTitle: String?
    var windowFrame: CGRect?
    var hasWebContent: Bool = false
    var containsSecureField: Bool = false
    /// Other sites' pages framed inside the window, sanitized; nil when none.
    var framedURLs: [String]?
    /// Some web content's address could not be read; nil when all could.
    var hasUnattributedWebContent: Bool?

    func privacyObservation(appName: String, bundleIdentifier: String?) -> ScreenContextPrivacy.Observation {
        .init(appName: appName, bundleIdentifier: bundleIdentifier,
              windowTitle: windowTitle, sourceURL: sourceURL,
              focusedSecureField: focusedSecureField, hasWebContent: hasWebContent,
              containsSecureField: containsSecureField, framedURLs: framedURLs ?? [],
              hasUnattributedWebContent: hasUnattributedWebContent ?? false)
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
        CaptureEnvironment.current.accessibility.read(processID: $0, includeText: false).snapshot
    }
    /// Metadata without the walk for web pages, for samples that need no page
    /// address (no site exclusions are configured).
    static let windowOnly = ScreenAccessibilityReader {
        CaptureEnvironment.current.accessibility.readWindow(processID: $0).snapshot
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
            CaptureEnvironment.current.accessibility.read(processID: processID, includeText: true).snapshot
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

    /// Why a text read produced no snapshot. Names the failed check, never
    /// window contents.
    struct TextReadFailure: Codable, Equatable, Sendable {
        let reason: String
        /// The window was readable but changed while it was read, as during
        /// a tab switch or page load; a read moments later can succeed.
        let isTransient: Bool
    }

    private static let failureLock = NSLock()
    private nonisolated(unsafe) static var textReadFailures: [pid_t: TextReadFailure] = [:]

    /// Why the most recent text read of `processID` produced no snapshot.
    static func lastTextReadFailure(for processID: pid_t) -> TextReadFailure? {
        failureLock.lock()
        defer { failureLock.unlock() }
        return textReadFailures[processID]
    }

    /// Replay and recording environments report a read's failure reason the
    /// same way a live read does, so capture retry logic sees it.
    static func recordTextReadFailure(_ failure: TextReadFailure?, processID: pid_t) {
        noteTextReadFailure(failure, processID: processID, includeText: true)
    }

    private static func noteTextReadFailure(_ reason: TextReadFailure?, processID: pid_t, includeText: Bool) {
        // Metadata-only activity sampling runs every few seconds; only the
        // screen-capture read is diagnosed.
        guard includeText else { return }
        failureLock.lock()
        defer { failureLock.unlock() }
        textReadFailures[processID] = reason
    }

    /// `walksWindow: false` reads only the window and its focused element:
    /// no text, web content, or page address (activity samples without site
    /// exclusions, which would otherwise walk up to 320 nodes every 5 s).
    static func resolve(processID: pid_t, includeText: Bool = true,
                        walksWindow: Bool = true) -> ScreenAccessibilitySnapshot? {
        func fail(_ reason: String, transient: Bool = false) -> ScreenAccessibilitySnapshot? {
            noteTextReadFailure(.init(reason: reason, isTransient: transient),
                                processID: processID, includeText: includeText)
            return nil
        }
        guard processID > 0, !isOwnProcess(processID) else { return nil }
        guard AXIsProcessTrusted() else { return fail("accessibility not trusted") }
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, perElementMessagingTimeout)
        guard let window = elementAttribute(app, kAXFocusedWindowAttribute as String) else {
            return fail("no focused window")
        }
        let windowTitle = textualAttribute(window, kAXTitleAttribute as String)
        let windowFrame = frame(of: window)

        let focused = elementAttribute(app, kAXFocusedUIElementAttribute as String)
        let focusedSecureField = focused.flatMap(secureFieldStatus)

        var queue: [(element: AXUIElement, viewport: CGRect?)] = [(window, windowFrame)]
        var visited = Set<CFHashCode>()
        var parts: [String] = []
        var seenText = Set<String>()
        let document = textualValue(attribute(window, kAXDocumentAttribute as String))
        var webAreaURLs: [String?] = []
        var hasWebContent = false
        var containsSecureField = false
        var totalCharacters = 0
        let started = ContinuousClock.now
        let maximumDuration = Duration.milliseconds(140)
        let maximumNodes = walksWindow || includeText ? 320 : 0
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
            if secure == true, Self.isTextEntry(role: role) { containsSecureField = true }
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
                webAreaURLs.append(urlString(attribute(element, kAXURLAttribute as String)))
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
              CFEqual(window, currentWindow) else {
            return fail("focused window changed during read", transient: true)
        }
        guard textualAttribute(currentWindow, kAXTitleAttribute as String) == windowTitle else {
            return fail("window title changed during read", transient: true)
        }
        guard frame(of: currentWindow) == windowFrame else {
            return fail("window frame changed during read", transient: true)
        }
        let finalFocus = elementAttribute(app, kAXFocusedUIElementAttribute as String)
            .flatMap(secureFieldStatus)
        let settledFocus = Self.settledFocus(before: focusedSecureField, after: finalFocus)
        guard settledFocus.accepted else {
            func describe(_ value: Bool?) -> String { value.map { $0 ? "secure" : "plain" } ?? "unknown" }
            return fail("focused-field state changed during read (\(describe(focusedSecureField))"
                + " to \(describe(finalFocus)))", transient: true)
        }
        noteTextReadFailure(nil, processID: processID, includeText: includeText)
        let text = parts.joined(separator: "\n")
        let address = pageAddress(document: document, webAreaURLs: webAreaURLs)
        return ScreenAccessibilitySnapshot(
            text: text,
            sourceURL: address.sourceURL,
            documentName: ScreenContextPrivacy.sanitizedDocumentName(document),
            focusedSecureField: settledFocus.focus,
            windowTitle: windowTitle,
            windowFrame: windowFrame,
            hasWebContent: hasWebContent,
            containsSecureField: containsSecureField,
            framedURLs: address.framedURLs.isEmpty ? nil : address.framedURLs,
            hasUnattributedWebContent: address.hasUnattributedWebContent ? true : nil)
    }

    struct PageAddress: Equatable, Sendable {
        /// The page's own address, as read.
        var sourceURL: String?
        /// Other sites' pages framed inside it, sanitized.
        var framedURLs: [String]
        /// A web area whose address could not be read.
        var hasUnattributedWebContent: Bool
    }

    /// Chrome exposes every frame of a page as its own web area: the page,
    /// about:blank editors, and other sites' embeds. The window's document,
    /// else the outermost web area, is the page; other addresses are kept for
    /// site exclusions instead of making the page's own address unknown.
    /// `webAreaURLs` lists web areas outermost first.
    static func pageAddress(document: String?, webAreaURLs: [String?]) -> PageAddress {
        var page = document.flatMap { ScreenContextPrivacy.sanitizedURL($0) == nil ? nil : $0 }
        var framed: [String] = []
        var unattributed = false
        for (index, raw) in webAreaURLs.enumerated() {
            guard let raw, !raw.isEmpty else {
                unattributed = true
                continue
            }
            // about:blank and about:srcdoc frames take their embedder's
            // origin, and a data: frame holds content its embedder supplied.
            let scheme = URL(string: raw)?.scheme?.lowercased() ?? ""
            if scheme == "about" || scheme == "data" { continue }
            // A blob: address carries the origin that created it.
            let address = scheme == "blob" ? String(raw.dropFirst("blob:".count)) : raw
            guard let sanitized = ScreenContextPrivacy.sanitizedURL(address) else {
                unattributed = true
                continue
            }
            if page == nil, index == 0 {
                page = raw
                continue
            }
            if sanitized != ScreenContextPrivacy.sanitizedURL(page), !framed.contains(sanitized) {
                framed.append(sanitized)
            }
        }
        return PageAddress(sourceURL: page, framedURLs: framed, hasUnattributedWebContent: unattributed)
    }

    /// The focused-field state across one read. Chrome reports no focused
    /// element until reading its page builds its accessibility tree, so an
    /// unknown focus that turns out to be a plain field keeps the read. Any
    /// other change, including into or out of a secure field, discards it.
    static func settledFocus(before: Bool?, after: Bool?) -> (accepted: Bool, focus: Bool?) {
        if before == after { return (true, before) }
        if before == nil, after == false { return (true, false) }
        return (false, before)
    }

    /// Only an input can hold a secret. The secure-field markers also match
    /// labels and buttons such as a browser's "Connection is secure" site
    /// information or "Manage passwords"; those stay out of captured text but
    /// do not make the whole window count as showing a password field.
    static func isTextEntry(role: String?) -> Bool {
        guard let role else { return false }
        return ["AXTextField", "AXSecureTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
            .contains(role)
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
