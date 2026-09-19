import AppKit
import ApplicationServices

/// Call lifecycle evidence is independent of audio and experimental speaker
/// observation. Only a supported meeting document and its call controls count.
enum BrowserMeetingSession {
    enum State: Equatable, Sendable { case inCall, ended, unavailable }
    struct Snapshot: Equatable, Sendable {
        var url: URL
        var state: State
    }
    private static let observationQueue = DispatchQueue(
        label: "me.dotenv.LokalBot.browser-observation", qos: .utility)

    static func observe(processIDs: [pid_t], expectedURL: URL?,
                        resolve: @escaping @Sendable (pid_t, URL?) -> Snapshot? = {
                            snapshot(processID: $0, expectedURL: $1)
                        }) async -> [pid_t: Snapshot] {
        await withCheckedContinuation { continuation in
            observationQueue.async {
                var snapshots: [pid_t: Snapshot] = [:]
                for pid in processIDs {
                    snapshots[pid] = resolve(pid, expectedURL)
                }
                continuation.resume(returning: snapshots)
            }
        }
    }

    struct Window {
        var element: AXUIElement
        var snapshot: Snapshot
    }

    /// AX is a best-effort source. A pathological background page must be
    /// isolated to its own window so it cannot consume the budget for the
    /// Meet document we are trying to verify.
    struct TraversalBudget {
        static let duration: TimeInterval = 0.25
        static let maximumNodes = 3_000
        static let maximumDepth = 30
        static let maximumChildren = 500

        private let deadline: TimeInterval
        private(set) var visitedNodes = 0

        init(startTime: TimeInterval) {
            deadline = startTime + Self.duration
        }

        mutating func visit(depth: Int, at now: TimeInterval) -> Bool {
            visitedNodes += 1
            return visitedNodes <= Self.maximumNodes
                && depth <= Self.maximumDepth
                && now < deadline
        }

        func allowsChildren(_ count: Int) -> Bool {
            count <= Self.maximumChildren
        }
    }

    struct StartGate {
        private var url: URL?
        private var since: Date?
        private var lastSeen: Date?

        mutating func observe(_ snapshot: Snapshot?, at now: Date) -> Bool {
            guard let snapshot, snapshot.state == .inCall else { self = Self(); return false }
            if url != snapshot.url || lastSeen.map({ now.timeIntervalSince($0) > 4 || now < $0 }) != false {
                url = snapshot.url
                since = now
            }
            lastSeen = now
            return since.map { now.timeIntervalSince($0) >= 2 } ?? false
        }
    }

    /// Lifecycle observations are allowed to be temporarily unavailable. A
    /// missing Accessibility snapshot is not the same evidence as a call that
    /// explicitly ended or a browser process that disappeared.
    enum LifecycleDecision: Equatable {
        case inCall
        case waitForObservation
        case endImmediately
        case endAfterGrace
    }

    static func lifecycleDecision(
        snapshotState: State?,
        hostPresent: Bool,
        observationLostAt: Date?,
        now: Date,
        grace: TimeInterval,
        hostReconnectGrace: TimeInterval? = nil
    ) -> LifecycleDecision {
        // A Chromium host can be replaced while its Meet tab and helper audio
        // continue (for example during a renderer/browser restart). Treat that
        // absence as a bounded reconnect window; an explicit ended snapshot is
        // still authoritative and stops immediately.
        if !hostPresent {
            let effectiveGrace = hostReconnectGrace ?? grace
            guard let observationLostAt,
                  effectiveGrace.isFinite,
                  effectiveGrace >= 0,
                  now.timeIntervalSince(observationLostAt) >= effectiveGrace else {
                return .waitForObservation
            }
            return .endAfterGrace
        }
        switch snapshotState {
        case .some(.inCall):
            return .inCall
        case .some(.ended):
            return .endImmediately
        case .some(.unavailable), .none:
            guard let observationLostAt,
                  grace.isFinite,
                  grace >= 0,
                  now.timeIntervalSince(observationLostAt) >= grace else {
                return .waitForObservation
            }
            return .endAfterGrace
        }
    }

    static func state(buttons: [String], messages: [String]) -> State {
        let buttons = buttons.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        let ended = messages.contains {
            ["you left the meeting", "you've left the meeting", "you have left the meeting",
             "you were removed from the meeting", "the meeting has ended"].contains($0.lowercased())
        }
        if ended { return .ended }
        let leaveLabels = ["leave call", "leave meeting", "hang up"]
        let leave = buttons.contains { label in
            leaveLabels.contains { action in
                label == action || label.hasPrefix("\(action) ") || label.hasPrefix("\(action)(")
            }
        }
        let microphone = buttons.contains { $0.hasPrefix("turn off microphone") || $0.hasPrefix("turn on microphone") }
        return leave && microphone ? .inCall : .unavailable
    }

    static func snapshot(processID: pid_t, expectedURL: URL? = nil) -> Snapshot? {
        window(processID: processID, expectedURL: expectedURL)?.snapshot
    }

    /// Enumerate browser windows, never just the focused window. Background
    /// documents unavailable through Accessibility safely abstain. No pixels,
    /// participant names, or page text are retained by lifecycle detection.
    static func window(processID: pid_t, expectedURL: URL?) -> Window? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, 0.012)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        let expected = expectedURL.flatMap { GoogleMeetSpeakerObservationProvider.meetURL($0.absoluteString) }
        guard expectedURL == nil || expected != nil,
              let windows = value(app, kAXWindowsAttribute) as? [AXUIElement], windows.count <= 32 else { return nil }
        var matches: [Window] = []
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        windowLoop: for window in windows {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            let title = value(window, kAXTitleAttribute) as? String ?? ""
            if ScreenContextPrivacy.isPrivateWindow(title: title)
                || value(window, kAXMinimizedAttribute) as? Bool == true { continue }
            var stack: [(AXUIElement, Int, Bool)] = [(window, 0, false)]
            var url: String?
            var buttons: [String] = []
            var messages: [String] = []
            var budget = TraversalBudget(startTime: ProcessInfo.processInfo.systemUptime)
            while let (node, depth, inside) = stack.popLast() {
                guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
                guard budget.visit(depth: depth, at: ProcessInfo.processInfo.systemUptime) else { continue windowLoop }
                guard let fields = fields(node) else { continue windowLoop }
                if fields["AXHidden"] as? Bool == true { continue }
                let role = fields[kAXRoleAttribute] as? String ?? ""
                var inDocument = inside
                if role == "AXWebArea" {
                    if inside { continue }
                    let raw = fields[kAXURLAttribute]
                    let text = (raw as? URL)?.absoluteString ?? (raw as? String) ?? ""
                    guard let valid = GoogleMeetSpeakerObservationProvider.meetURL(text),
                          expected == nil || valid == expected else { continue }
                    guard url == nil else { continue windowLoop }
                    url = valid
                    inDocument = true
                }
                if inDocument && ["AXButton", "AXStaticText", "AXHeading"].contains(role) {
                    let labels = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
                        .compactMap { fields[$0] as? String }.filter { $0.count <= 160 }
                    if role == "AXButton" { buttons += labels } else { messages += labels }
                }
                let children = fields[kAXChildrenAttribute] as? [AXUIElement] ?? []
                guard budget.allowsChildren(children.count) else { continue windowLoop }
                stack += children.reversed().map { ($0, depth + 1, inDocument) }
            }
            if let url, let parsed = URL(string: url) {
                let match = Window(element: window, snapshot: Snapshot(url: parsed, state: state(buttons: buttons, messages: messages)))
                matches.append(match)
                // An expected URL is already the caller's binding. Return a
                // positive call-control match immediately so unrelated heavy
                // windows later in the AX list cannot add latency or fail the
                // bound meeting lookup.
                if expected != nil, match.snapshot.state == .inCall { return match }
            }
        }
        // Multiple unrelated Meet windows cannot silently pick the first call.
        if expected == nil {
            let calls = matches.filter { $0.snapshot.state == .inCall }
            return calls.count == 1 ? calls.first : nil
        }
        return matches.count == 1 ? matches.first : nil
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
    }

    private static func fields(_ element: AXUIElement) -> [String: AnyObject]? {
        let keys = [kAXRoleAttribute, kAXURLAttribute, kAXChildrenAttribute, kAXTitleAttribute,
                    kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute, kAXSelectedAttribute, "AXHidden"]
        var result: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, keys as CFArray,
                AXCopyMultipleAttributeOptions(rawValue: 0), &result) == .success,
              let values = result as? [AnyObject], values.count == keys.count else { return nil }
        return Dictionary(uniqueKeysWithValues: zip(keys, values))
    }
}
