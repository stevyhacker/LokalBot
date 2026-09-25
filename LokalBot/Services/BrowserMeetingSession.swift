import AppKit
import ApplicationServices

/// Call lifecycle evidence is independent of audio. Only a supported meeting
/// document and its call controls count.
enum BrowserMeetingSession {
    /// `present`: the verified window still holds the call's tab, but its call
    /// controls cannot be read (a large page, a slow tree, another tab in front).
    /// `gone`: that window was closed or no longer holds the call's tab.
    enum State: Equatable, Sendable { case inCall, minimized, present, ended, gone, unavailable }
    struct Snapshot: Equatable, Sendable {
        var url: URL
        var state: State
    }

    /// The canonical meeting-room URL, or nil for anything that is not an
    /// exact https://meet.google.com/abc-defg-hij document.
    nonisolated static func meetURL(_ raw: String) -> String? {
        guard let components = URLComponents(string: raw), components.scheme == "https",
              components.host?.lowercased() == "meet.google.com", components.user == nil, components.password == nil,
              components.port == nil || components.port == 443,
              components.path.range(of: #"^/[a-z]{3}-[a-z]{4}-[a-z]{3}$"#, options: .regularExpression) != nil else { return nil }
        return "https://meet.google.com" + components.path
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
        /// The window title when its call was verified, i.e. the call tab's title.
        var title = ""
    }

    /// Why the last lifecycle read of a browser found no call document.
    enum ReadIssue: String, Sendable {
        case accessibilityUntrusted, windowListUnavailable, tooManyWindows, deadline
        case pageTooLarge, accessibilityTimeout, noMeetingDocument, ambiguousWindows
    }

    /// Only a previously verified window can suspend lifecycle observations.
    /// Another browser window or unrelated audio cannot acquire this binding.
    private final class WindowBindings: @unchecked Sendable {
        private let lock = NSLock()
        private var windows: [pid_t: Window] = [:]

        func get(_ pid: pid_t) -> Window? {
            lock.lock()
            defer { lock.unlock() }
            return windows[pid]
        }

        func set(_ window: Window?, for pid: pid_t) {
            lock.lock()
            defer { lock.unlock() }
            windows[pid] = window
        }
    }
    private static let bindings = WindowBindings()

    private final class ReadIssues: @unchecked Sendable {
        private let lock = NSLock()
        private var issues: [pid_t: ReadIssue] = [:]

        func get(_ pid: pid_t) -> ReadIssue? {
            lock.lock()
            defer { lock.unlock() }
            return issues[pid]
        }

        func set(_ issue: ReadIssue?, for pid: pid_t) {
            lock.lock()
            defer { lock.unlock() }
            issues[pid] = issue
        }
    }
    private static let readIssues = ReadIssues()

    /// Diagnostics only: why the latest read of this browser found no call.
    static func lastReadIssue(processID: pid_t) -> ReadIssue? { readIssues.get(processID) }

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
        case visibilitySuspended
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
        case .some(.minimized), .some(.present):
            // A minimized window, or a call tab whose controls are unreadable,
            // cannot expose call controls, so it is not fresh call evidence. It
            // is, however, positive evidence that the exact previously verified
            // window still holds the call. Keep that recording until the
            // controls return, the tab/window/host disappears, or an explicit
            // ended state is seen. Neither can pass StartGate and begin a session.
            return .visibilitySuspended
        case .some(.ended):
            return .endImmediately
        case .some(.gone), .some(.unavailable), .none:
            guard let observationLostAt,
                  grace.isFinite,
                  grace >= 0,
                  now.timeIntervalSince(observationLostAt) >= grace else {
                return .waitForObservation
            }
            return .endAfterGrace
        }
    }

    /// One bound call's lifecycle across detector ticks: when certainty was
    /// lost, the last moment the call was known to continue, and whether an
    /// end is confident. Only a grace expiry with nothing readable at all is
    /// uncertain; a readable page without call controls or a closed tab is not.
    struct LifecycleTracker: Equatable {
        enum Event: Equatable {
            case none
            case lost(State?)
            case suspended(State)
            case recovered(after: TimeInterval)
            case end(reason: String, confident: Bool, contentEnd: Date)
        }

        private(set) var lostAt: Date?
        private(set) var suspension: State?
        private var suspendedAt: Date?
        /// In-call controls, or the verified window still holding the call.
        private(set) var lastEvidenceAt: Date?
        private var lastUncertainState: State?

        init(verifiedAt: Date? = nil) {
            lastEvidenceAt = verifiedAt
        }

        mutating func observe(_ state: State?, hostPresent: Bool, now: Date,
                              grace: TimeInterval, hostReconnectGrace: TimeInterval) -> Event {
            let decision = BrowserMeetingSession.lifecycleDecision(
                snapshotState: state, hostPresent: hostPresent,
                observationLostAt: lostAt ?? now, now: now,
                grace: grace, hostReconnectGrace: hostReconnectGrace)
            switch decision {
            case .inCall:
                let since = suspendedAt ?? lostAt
                self = Self(verifiedAt: now)
                return since.map { .recovered(after: now.timeIntervalSince($0)) } ?? .none
            case .visibilitySuspended:
                // The window still holds the call, so the grace clock restarts
                // and a later uncertain period gets its full grace.
                let changed = suspension != state
                if suspendedAt == nil { suspendedAt = lostAt ?? now }
                lostAt = nil
                lastUncertainState = nil
                lastEvidenceAt = now
                suspension = state
                return changed ? state.map(Event.suspended) ?? .none : .none
            case .waitForObservation:
                lastUncertainState = hostPresent ? state : nil
                guard lostAt == nil else { return .none }
                lostAt = now
                return .lost(state)
            case .endImmediately:
                return .end(reason: "browser-ended", confident: true, contentEnd: lastEvidenceAt ?? now)
            case .endAfterGrace:
                let known = state ?? lastUncertainState
                let reason = !hostPresent ? "browser-host-reconnect-grace-expired"
                    : known == .gone ? "browser-meeting-closed"
                    : known == .unavailable ? "browser-call-controls-missing"
                    : "browser-observation-grace-expired"
                return .end(reason: reason, confident: reason != "browser-observation-grace-expired",
                            contentEnd: lastEvidenceAt ?? lostAt ?? now)
            }
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
        let observed = window(processID: processID, expectedURL: expectedURL)
        if observed?.snapshot.state == .inCall {
            bindings.set(observed, for: processID)
        } else if observed?.snapshot.state == .ended {
            bindings.set(nil, for: processID)
        } else if let expectedURL, let bound = bindings.get(processID), bound.snapshot.url == expectedURL,
                  let state = boundWindowState(processID: processID, bound: bound,
                                               documentReadable: observed != nil) {
            return Snapshot(url: expectedURL, state: state)
        }
        return observed?.snapshot
    }

    /// What the exact verified window shows when its call controls were not
    /// read. Nil keeps today's uncertainty: the window list or tab strip could
    /// not be read, or the call document itself was readable without controls.
    private static func boundWindowState(processID: pid_t, bound: Window, documentReadable: Bool) -> State? {
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, 0.012)
        // A closed window or replacement process no longer holds the call.
        guard let windows = value(app, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        guard windows.contains(where: { CFEqual($0, bound.element) }) else { return .gone }
        guard let title = value(bound.element, kAXTitleAttribute) as? String,
              !ScreenContextPrivacy.isPrivateWindow(title: title) else { return nil }
        if value(bound.element, kAXMinimizedAttribute) as? Bool == true { return .minimized }
        guard !documentReadable else { return nil }
        let url = bound.snapshot.url
        if titleNamesCall(title, url: url, verifiedTitle: bound.title) { return .present }
        guard let tabHoldsCall = tabStripContains(in: bound.element, where: {
            titleNamesCall($0, url: url, verifiedTitle: bound.title)
        }) else { return nil }
        if tabHoldsCall { return .present }
        // Only call a tab closed when its title was recognisable to begin with.
        return titleNamesCall(bound.title, url: url, verifiedTitle: "") ? .gone : nil
    }

    /// Whether a window or tab title still names the verified call. Meet puts
    /// the room code in its title; the title seen at verification also counts,
    /// including Chrome's appended tab states such as "- Audio playing".
    static func titleNamesCall(_ title: String, url: URL, verifiedTitle: String) -> Bool {
        let candidate = title.lowercased()
        let code = url.lastPathComponent.lowercased()
        if code.count >= 10, candidate.contains(code) { return true }
        let verified = verifiedTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !["", "meet", "google meet"].contains(verified) && candidate.hasPrefix(verified)
    }

    /// Searches the window's tab strip (the first tab group outside page
    /// content). Nil when the strip is not found or not read completely.
    private static func tabStripContains(in window: AXUIElement, where matches: (String) -> Bool) -> Bool? {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.3
        func children(_ fields: [String: AnyObject]) -> [AXUIElement] {
            let children = fields[kAXChildrenAttribute] as? [AXUIElement] ?? []
            return children.count <= TraversalBudget.maximumChildren ? children : []
        }
        var queue: [(element: AXUIElement, depth: Int)] = [(window, 0)]
        var index = 0
        var strip: AXUIElement?
        while strip == nil, index < queue.count {
            guard index < 800, ProcessInfo.processInfo.systemUptime < deadline,
                  let fields = fields(queue[index].element) else { return nil }
            let (element, depth) = queue[index]
            index += 1
            switch fields[kAXRoleAttribute] as? String {
            case "AXWebArea": continue
            case "AXTabGroup": strip = element
            default: if depth < 12 { queue += children(fields).map { ($0, depth + 1) } }
            }
        }
        guard let strip else { return nil }
        // Tabs may sit inside named tab groups, so scan a few levels down.
        var stack: [(element: AXUIElement, depth: Int)] = [(strip, 0)]
        var visited = 0
        while let (element, depth) = stack.popLast() {
            visited += 1
            guard visited <= 600, ProcessInfo.processInfo.systemUptime < deadline,
                  let fields = fields(element) else { return nil }
            if fields[kAXRoleAttribute] as? String == "AXRadioButton",
               [kAXTitleAttribute, kAXDescriptionAttribute].contains(where: { (fields[$0] as? String).map(matches) == true }) {
                return true
            }
            if depth < 4 { stack += children(fields).map { ($0, depth + 1) } }
        }
        return false
    }

    /// Enumerate browser windows, never just the focused window. Background
    /// documents unavailable through Accessibility safely abstain. No pixels,
    /// participant names, or page text are retained by lifecycle detection.
    static func window(processID: pid_t, expectedURL: URL?, preferFocused: Bool = false) -> Window? {
        var issue = ReadIssue.noMeetingDocument
        let found = window(processID: processID, expectedURL: expectedURL, preferFocused: preferFocused, issue: &issue)
        readIssues.set(found == nil ? issue : nil, for: processID)
        return found
    }

    private static func window(processID: pid_t, expectedURL: URL?, preferFocused: Bool,
                               issue: inout ReadIssue) -> Window? {
        guard AXIsProcessTrusted() else { issue = .accessibilityUntrusted; return nil }
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, 0.012)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        let expected = expectedURL.flatMap { meetURL($0.absoluteString) }
        guard expectedURL == nil || expected != nil else { return nil }
        guard let windows = value(app, kAXWindowsAttribute) as? [AXUIElement] else {
            issue = .windowListUnavailable
            return nil
        }
        guard windows.count <= 32 else { issue = .tooManyWindows; return nil }
        var matches: [Window] = []
        let focused = value(app, kAXFocusedWindowAttribute)
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        windowLoop: for window in windows {
            guard ProcessInfo.processInfo.systemUptime < deadline else { issue = .deadline; return nil }
            let title = value(window, kAXTitleAttribute) as? String ?? ""
            if ScreenContextPrivacy.isPrivateWindow(title: title)
                || value(window, kAXMinimizedAttribute) as? Bool == true { continue }
            var stack: [(AXUIElement, Int, Bool)] = [(window, 0, false)]
            var url: String?
            var buttons: [String] = []
            var messages: [String] = []
            var budget = TraversalBudget(startTime: ProcessInfo.processInfo.systemUptime)
            while let (node, depth, inside) = stack.popLast() {
                guard ProcessInfo.processInfo.systemUptime < deadline else { issue = .deadline; return nil }
                guard budget.visit(depth: depth, at: ProcessInfo.processInfo.systemUptime) else {
                    issue = .pageTooLarge
                    continue windowLoop
                }
                guard let fields = fields(node) else { issue = .accessibilityTimeout; continue windowLoop }
                if fields["AXHidden"] as? Bool == true { continue }
                let role = fields[kAXRoleAttribute] as? String ?? ""
                var inDocument = inside
                if role == "AXWebArea" {
                    if inside { continue }
                    let raw = fields[kAXURLAttribute]
                    let text = (raw as? URL)?.absoluteString ?? (raw as? String) ?? ""
                    guard let valid = meetURL(text),
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
                guard budget.allowsChildren(children.count) else { issue = .pageTooLarge; continue windowLoop }
                stack += children.reversed().map { ($0, depth + 1, inDocument) }
            }
            if let url, let parsed = URL(string: url) {
                let match = Window(element: window, snapshot: Snapshot(url: parsed, state: state(buttons: buttons, messages: messages)),
                                   title: title)
                matches.append(match)
                // An expected URL is already the caller's binding. Return a
                // positive call-control match immediately so unrelated heavy
                // windows later in the AX list cannot add latency or fail the
                // bound meeting lookup.
                if expected != nil, match.snapshot.state == .inCall, !preferFocused { return match }
            }
        }
        if matches.count > 1 { issue = .ambiguousWindows }
        if preferFocused {
            let calls = matches.filter { $0.snapshot.state == .inCall }
            if let focused, let match = calls.first(where: { CFEqual($0.element, focused) }) { return match }
            return calls.count == 1 ? calls.first : nil
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
