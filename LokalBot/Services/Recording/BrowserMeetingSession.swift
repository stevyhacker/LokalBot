import AppKit
import ApplicationServices

/// Call lifecycle evidence is independent of audio. Only a supported meeting
/// document and its call controls count.
enum BrowserMeetingSession {
    /// `present`: the verified window still holds the call's tab, but its call
    /// controls cannot be read (a large page, a slow tree, another tab in front).
    /// `gone`: that window was closed or no longer holds the call's tab.
    enum State: String, Codable, Equatable, Sendable {
        case inCall, minimized, present, ended, gone, unavailable, waitingRoom
    }
    struct Snapshot: Codable, Equatable, Sendable {
        var url: URL
        var state: State
    }

    typealias Service = ConferenceRoom.Service

    // The MTS Link desktop app also plays chat notifications and voice messages.
    // Verify its conference web view instead of treating audio as a meeting.
    nonisolated static let nativeWebClients: [String: Service] = ["ru.weteams.desktop": .mtsLink]

    nonisolated static func roomURL(_ raw: String) -> String? { ConferenceRoom(raw)?.url }

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

    /// A browser microphone identifies a process family, so a private or
    /// unreadable window in that family blocks the optional fallback.
    static func microphoneFallbackWindowsAllowed(_ titles: [String?]) -> Bool {
        !titles.isEmpty && titles.allSatisfy { title in
            guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            return !ScreenContextPrivacy.isPrivateWindow(title: title)
        }
    }

    static func microphoneFallbackAllowed(processIDs: [pid_t]) async -> Set<pid_t> {
        guard !processIDs.isEmpty else { return [] }
        return await withCheckedContinuation { continuation in
            observationQueue.async {
                guard AXIsProcessTrusted() else { continuation.resume(returning: []); return }
                let eligible = processIDs.filter { pid in
                    let app = AXUIElementCreateApplication(pid)
                    AXUIElementSetMessagingTimeout(app, 0.012)
                    guard let windows = value(app, kAXWindowsAttribute) as? [AXUIElement],
                          windows.count <= 32 else { return false }
                    return microphoneFallbackWindowsAllowed(windows.map {
                        value($0, kAXTitleAttribute) as? String
                    })
                }
                continuation.resume(returning: Set(eligible))
            }
        }
    }

    struct Window {
        var element: AXUIElement
        var snapshot: Snapshot
        /// The window title when its call was verified, i.e. the call tab's title.
        var title = ""
    }

    /// What a complete AX read proved about the expected room and its windows.
    private struct WindowRead {
        var windows: [AXUIElement]?
        var inspected: [AXUIElement] = []
        var landing: [AXUIElement] = []
        var expectedRoomSeen = false
    }

    static func nativeWindowState(roomSeen: Bool, allWindowsInspected: Bool, minimized: Bool) -> State? {
        if minimized { return .minimized }
        if roomSeen { return .present }
        return allWindowsInspected ? .ended : nil
    }

    static func landingState(boundWindowOnLanding: Bool, tabHoldsRoom: Bool?) -> State? {
        boundWindowOnLanding && tabHoldsRoom == false ? .ended : nil
    }

    /// Why the last lifecycle read of a browser found no call document.
    enum ReadIssue: String, Codable, Sendable {
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
    /// meeting document we are trying to verify.
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
        grace: TimeInterval
    ) -> LifecycleDecision {
        // A missing host/document or unreadable controls cannot prove an end.
        // Keep the authorized capture and its binding alive until positive end
        // evidence or the user's Stop action, however long observation takes.
        guard hostPresent || snapshotState == .ended else { return .waitForObservation }
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
        case .some(.unavailable), .some(.waitingRoom), .none:
            return .waitForObservation
        case .some(.gone):
            guard let observationLostAt,
                  grace.isFinite,
                  grace >= 0,
                  now.timeIntervalSince(observationLostAt) >= grace else {
                return .waitForObservation
            }
            return .endAfterGrace
        }
    }

    /// One bound call's lifecycle. Uncertainty never expires the authorization
    /// to keep recording. Only continuously verified closure starts end grace.
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
        private var closedAt: Date?

        init(verifiedAt: Date? = nil) {
            lastEvidenceAt = verifiedAt
        }

        mutating func observe(_ state: State?, hostPresent: Bool, now: Date,
                              grace: TimeInterval) -> Event {
            let decision = BrowserMeetingSession.lifecycleDecision(
                snapshotState: state, hostPresent: hostPresent,
                observationLostAt: state == .gone ? (closedAt ?? now) : lostAt, now: now,
                grace: grace)
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
                closedAt = nil
                lastEvidenceAt = now
                suspension = state
                return changed ? state.map(Event.suspended) ?? .none : .none
            case .waitForObservation:
                if hostPresent, state == .gone {
                    if closedAt == nil { closedAt = now }
                } else {
                    closedAt = nil
                }
                guard lostAt == nil else { return .none }
                lostAt = now
                return .lost(state)
            case .endImmediately:
                return .end(reason: "browser-ended", confident: true, contentEnd: now)
            case .endAfterGrace:
                return .end(reason: "browser-meeting-closed", confident: true,
                            contentEnd: closedAt ?? now)
            }
        }
    }

    static func state(buttons: [String], messages: [String], service: Service = .googleMeet,
                      disabledButtons: [String] = []) -> State {
        func normalize(_ label: String) -> String {
            label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let buttons = buttons.map(normalize)
        let ended = messages.contains {
            ["you left the meeting", "you've left the meeting", "you have left the meeting",
             "you were removed from the meeting", "the meeting has ended"].contains($0.lowercased())
        }
        if ended { return .ended }
        func offers(_ action: String) -> Bool {
            buttons.contains { $0 == action || $0.hasPrefix("\(action) ") || $0.hasPrefix("\(action)(") }
        }
        if service != .googleMeet {
            let mic = ["включить микрофон", "выключить микрофон",
                       "turn on microphone", "turn off microphone", "mute microphone", "unmute microphone"]
            // Match the actual toggles, not menu labels such as "Включить микрофон Меню".
            let hasMic = mic.contains(where: buttons.contains)
            switch service {
            case .telemost:
                let leave = ["выйти из встречи", "завершить звонок", "leave meeting", "end call"]
                return hasMic && leave.contains(where: buttons.contains) ? .inCall : .unavailable
            case .mtsLink:
                // Its device preview renders behind a dialog, with the room's
                // own Leave button. The Join action is a veto, even in that tree.
                let join = ["присоединиться к встрече", "join the meeting", "join meeting"]
                let leave = ["покинуть встречу", "leave the meeting", "leave meeting"]
                let roomControls = ["участники", "participants", "поднять руку", "raise hand"]
                let allButtons = buttons + disabledButtons.map(normalize)
                let hasJoin = join.contains(where: allButtons.contains)
                if hasJoin { return .waitingRoom }
                return hasMic && leave.contains(where: buttons.contains)
                    && roomControls.contains(where: buttons.contains) ? .inCall : .unavailable
            case .googleMeet: break
            }
        }
        let leave = ["leave call", "leave meeting", "hang up"].contains(where: offers)
        let microphone = buttons.contains { $0.hasPrefix("turn off microphone") || $0.hasPrefix("turn on microphone") }
        if leave && microphone { return .inCall }
        // Meet's page after a call offers to rejoin it or go home, whatever its
        // heading says (left, removed, ended by the host). With the call
        // controls gone, that pair is end evidence where the wording is not.
        return !leave && offers("rejoin") && offers("return to home screen") ? .ended : .unavailable
    }

    static func snapshot(processID: pid_t, expectedURL: URL? = nil) -> Snapshot? {
        CaptureEnvironment.current.accessibility.browserMeetingSnapshot(processID: processID, expectedURL: expectedURL)
    }

    static func liveSnapshot(processID: pid_t, expectedURL: URL? = nil) -> Snapshot? {
        let canonical = expectedURL.flatMap { roomURL($0.absoluteString) }
        let bound = bindings.get(processID).flatMap {
            $0.snapshot.url.absoluteString == canonical ? $0 : nil
        }
        let bundleID = cachedBundleID(processID: processID)
        let native = bundleID.flatMap { nativeWebClients[$0] }
        var read = WindowRead()
        let observed = observeWindow(processID: processID, expectedURL: expectedURL, preferFocused: false,
                                     bundleID: bundleID, bound: bound, read: &read, includeInactive: true)
        if observed?.snapshot.state == .inCall {
            bindings.set(observed, for: processID)
        } else if observed?.snapshot.state == .ended {
            bindings.set(nil, for: processID)
        } else if let bound {
            let state: State?
            if observed?.snapshot.state == .waitingRoom {
                state = .ended
            } else if native != nil {
                let stillOpen = read.windows?.contains { CFEqual($0, bound.element) } == true
                let minimized = stillOpen && value(bound.element, kAXMinimizedAttribute) as? Bool == true
                state = nativeWindowState(roomSeen: read.expectedRoomSeen,
                    allWindowsInspected: read.windows?.count == read.inspected.count, minimized: minimized)
            } else {
                state = boundWindowState(bound: bound, read: read, documentReadable: observed != nil)
            }
            if let state {
                if state == .ended { bindings.set(nil, for: processID) }
                return Snapshot(url: bound.snapshot.url, state: state)
            }
        }
        return observed?.snapshot
    }

    /// What the exact verified window shows when its call controls were not
    /// read. Nil keeps today's uncertainty: the window list or tab strip could
    /// not be read, or the call document itself was readable without controls.
    private static func boundWindowState(bound: Window, read: WindowRead, documentReadable: Bool) -> State? {
        // A moved tab can replace its original window. Inspect every window
        // before calling the bound call closed; unreadable strips abstain.
        guard let windows = read.windows else { return nil }
        guard windows.contains(where: { CFEqual($0, bound.element) }) else {
            return closureState(in: windows, bound: bound)
        }
        guard let title = value(bound.element, kAXTitleAttribute) as? String,
              !ScreenContextPrivacy.isPrivateWindow(title: title) else { return nil }
        if value(bound.element, kAXMinimizedAttribute) as? Bool == true { return .minimized }
        guard !documentReadable else { return nil }
        let url = bound.snapshot.url
        let onLanding = read.landing.contains { CFEqual($0, bound.element) }
        let namesRoom = titleNamesCall(title, url: url, verifiedTitle: bound.title)
        if namesRoom, !onLanding { return .present }
        let tabHoldsCall = tabStripContains(in: bound.element, where: {
            titleNamesCall($0, url: url, verifiedTitle: bound.title)
        })
        if let ended = landingState(boundWindowOnLanding: onLanding, tabHoldsRoom: tabHoldsCall) {
            return ended
        }
        if namesRoom { return .present }
        guard let tabHoldsCall else { return nil }
        if tabHoldsCall { return .present }
        // Only call a tab closed when its title was recognisable to begin with.
        return closureState(in: windows, bound: bound)
    }

    private static func closureState(in windows: [AXUIElement], bound: Window) -> State? {
        let url = bound.snapshot.url
        // Meet has a room code in its tab title. The other services can show
        // just the call title, so use the exact title we verified in the room.
        let fallbackTitle = url.host == Service.googleMeet.rawValue ? "" : bound.title
        guard titleNamesCall(bound.title, url: url, verifiedTitle: fallbackTitle) else { return nil }
        for window in windows {
            guard let title = value(window, kAXTitleAttribute) as? String,
                  !ScreenContextPrivacy.isPrivateWindow(title: title) else { return nil }
            if titleNamesCall(title, url: bound.snapshot.url, verifiedTitle: bound.title) { return .present }
            guard let contains = tabStripContains(in: window, where: {
                titleNamesCall($0, url: bound.snapshot.url, verifiedTitle: bound.title)
            }) else { return nil }
            if contains { return .present }
        }
        return .gone
    }

    /// Whether a window or tab title still names the verified call. Meet puts
    /// the room code in its title; the title seen at verification also counts,
    /// including Chrome's appended tab states such as "- Audio playing".
    static func titleNamesCall(_ title: String, url: URL, verifiedTitle: String) -> Bool {
        let candidate = title.lowercased()
        let code = url.lastPathComponent.lowercased()
        if code.count >= 10, candidate.contains(code) { return true }
        let verified = verifiedTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let generic = ["", "meet", "google meet", "телемост", "яндекс телемост", "yandex telemost",
                       "мтс линк", "мтс линк встречи", "mts link"]
        guard !generic.contains(verified) else { return false }
        if url.host == Service.googleMeet.rawValue { return candidate.hasPrefix(verified) }
        // Chrome can prefix the localized tab label and quote the title,
        // then append a group name or a microphone/audio indicator. This
        // comparison only keeps an existing binding; it cannot start one.
        return candidate.contains(verified)
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
        var read = WindowRead()
        return observeWindow(processID: processID, expectedURL: expectedURL, preferFocused: preferFocused,
                             bundleID: cachedBundleID(processID: processID), bound: nil, read: &read)
    }

    private static func cachedBundleID(processID: pid_t) -> String? {
        RunningApplicationCache.shared.runningApplications().first {
            $0.processIdentifier == processID
        }?.bundleIdentifier
    }

    private static func observeWindow(processID: pid_t, expectedURL: URL?, preferFocused: Bool,
                                      bundleID: String?, bound: Window?, read: inout WindowRead,
                                      includeInactive: Bool = false) -> Window? {
        var issue = ReadIssue.noMeetingDocument
        let found = window(processID: processID, expectedURL: expectedURL, preferFocused: preferFocused,
                           bundleID: bundleID, bound: bound, read: &read,
                           includeInactive: includeInactive, issue: &issue)
        readIssues.set(found == nil ? issue : nil, for: processID)
        return found
    }

    private static func window(processID: pid_t, expectedURL: URL?, preferFocused: Bool,
                               bundleID: String?, bound: Window?, read: inout WindowRead,
                               includeInactive: Bool, issue: inout ReadIssue) -> Window? {
        guard AXIsProcessTrusted() else { issue = .accessibilityUntrusted; return nil }
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, 0.012)
        primeWebAccessibility(app, processID: processID, bundleID: bundleID)
        let expected = expectedURL.flatMap { roomURL($0.absoluteString) }
        let nativeService = bundleID.flatMap { nativeWebClients[$0] }
        let boundRoom = bound.flatMap { ConferenceRoom($0.snapshot.url.absoluteString) }
        guard expectedURL == nil || expected != nil else { return nil }
        guard let windows = value(app, kAXWindowsAttribute) as? [AXUIElement] else {
            issue = .windowListUnavailable
            return nil
        }
        guard windows.count <= 32 else { issue = .tooManyWindows; return nil }
        read.windows = windows
        var matches: [Window] = []
        let focused = value(app, kAXFocusedWindowAttribute)
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        quietWindows.keep(only: windows, processID: processID)
        let ordered = bound.map { call in
            windows.filter { CFEqual($0, call.element) } + windows.filter { !CFEqual($0, call.element) }
        } ?? windows
        windowLoop: for window in ordered {
            guard ProcessInfo.processInfo.systemUptime < deadline else { issue = .deadline; return nil }
            let title = value(window, kAXTitleAttribute) as? String ?? ""
            if ScreenContextPrivacy.isPrivateWindow(title: title)
                || value(window, kAXMinimizedAttribute) as? Bool == true { continue }
            let started = ProcessInfo.processInfo.systemUptime
            let checksNativeClosure = bound != nil && nativeService != nil
            let isBoundWindow = bound.map { CFEqual($0.element, window) } == true
            if !checksNativeClosure, !isBoundWindow,
               quietWindows.isQuiet(window, title: title, processID: processID, now: started) {
                continue
            }
            var stack: [(AXUIElement, Int, Bool)] = [(window, 0, false)]
            var room: ConferenceRoom?
            var roomTitle: String?
            var telemostCallState: State?
            var sawMeetingDocument = false
            var buttons: [String] = []
            var disabledButtons: [String] = []
            var messages: [String] = []
            var budget = TraversalBudget(startTime: started)
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
                    let raw = fields[kAXURLAttribute]
                    let text = (raw as? URL)?.absoluteString ?? (raw as? String) ?? ""
                    if inside { continue }
                    if isBoundWindow, boundRoom?.isPostCallPage(text) == true {
                        read.landing.append(window)
                    }
                    if let candidate = ConferenceRoom(text), nativeService == nil || candidate.service == nativeService {
                        sawMeetingDocument = true
                        guard expected == nil || candidate.url == expected else { continue }
                        if expected == candidate.url { read.expectedRoomSeen = true }
                        guard room == nil else { continue windowLoop }
                        room = candidate
                        roomTitle = fields[kAXTitleAttribute] as? String
                        if candidate.service == .telemost {
                            telemostCallState = readTelemostCall(
                                in: fields[kAXChildrenAttribute] as? [AXUIElement] ?? [],
                                room: candidate, depth: depth + 1, budget: &budget)
                            continue
                        }
                        inDocument = true
                    } else if nativeService == nil {
                        // Never look for a conferencing iframe on an unrelated
                        // browser site. A known desktop client may embed its own web view.
                        continue
                    }
                }
                if inDocument && ["AXButton", "AXLink", "AXStaticText", "AXHeading"].contains(role) {
                    let labels = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
                        .compactMap { fields[$0] as? String }.filter { $0.count <= 160 }
                    if room?.service == .googleMeet {
                        // Meet's post-call actions may be links rather than buttons.
                        if role == "AXButton" || role == "AXLink" { buttons += labels } else { messages += labels }
                    } else if role == "AXButton" {
                        if fields[kAXEnabledAttribute] as? Bool == false { disabledButtons += labels } else { buttons += labels }
                    }
                }
                let children = fields[kAXChildrenAttribute] as? [AXUIElement] ?? []
                guard budget.allowsChildren(children.count) else { issue = .pageTooLarge; continue windowLoop }
                stack += children.reversed().map { ($0, depth + 1, inDocument) }
            }
            // Only a complete read without any meeting document is remembered.
            quietWindows.record(window, title: title, quiet: !sawMeetingDocument,
                                processID: processID, now: started)
            read.inspected.append(window)
            if let room, let parsed = URL(string: room.url) {
                let callState = telemostCallState ?? state(buttons: buttons, messages: messages,
                                                           service: room.service, disabledButtons: disabledButtons)
                let match = Window(element: window, snapshot: Snapshot(url: parsed, state: callState),
                                   title: room.service == .googleMeet ? title : roomTitle ?? title)
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
        // Multiple unrelated meeting windows cannot silently pick the first call.
        if expected == nil {
            let calls = matches.filter { $0.snapshot.state == .inCall }
            if calls.count == 1 { return calls.first }
            if includeInactive, var identified = matches.first {
                if matches.count > 1 { identified.snapshot.state = .unavailable }
                return identified
            }
            return nil
        }
        return matches.count == 1 ? matches.first : nil
    }

    /// Telemost keeps the entire chat application in the meeting page. Find
    /// the call toolbar before walking deep chat lists; those lists can use
    /// the full window budget even when the call controls are easy to reach.
    private static func readTelemostCall(in children: [AXUIElement], room: ConferenceRoom, depth: Int,
                                         budget: inout TraversalBudget) -> State {
        guard budget.allowsChildren(children.count) else { return .unavailable }
        var queue = children.map { ($0, depth) }
        var index = 0
        var buttons: [String] = []
        while index < queue.count {
            let (node, depth) = queue[index]
            index += 1
            guard depth <= TraversalBudget.maximumDepth else { break }
            guard budget.visit(depth: depth, at: ProcessInfo.processInfo.systemUptime) else { break }
            guard let fields = fields(node), fields["AXHidden"] as? Bool != true else { continue }
            let role = fields[kAXRoleAttribute] as? String
            if role == "AXWebArea" {
                let raw = fields[kAXURLAttribute]
                let address = (raw as? URL)?.absoluteString ?? (raw as? String) ?? ""
                guard room.acceptsFrame(address) else { continue }
            }
            if role == "AXButton", fields[kAXEnabledAttribute] as? Bool != false {
                buttons += [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
                    .compactMap { fields[$0] as? String }.filter { $0.count <= 160 }
                if state(buttons: buttons, messages: [], service: .telemost) == .inCall { return .inCall }
            }
            if let children = fields[kAXChildrenAttribute] as? [AXUIElement], budget.allowsChildren(children.count) {
                let slots = max(0, TraversalBudget.maximumNodes - queue.count)
                queue += children.prefix(slots).map { ($0, depth + 1) }
            }
        }
        return .unavailable
    }

    /// Browser windows whose last complete read found no meeting document. A meeting
    /// tab coming to the front or loading replaces the window's title, so a
    /// window keeping its title is not walked again until `maximumAge` passes.
    /// Each walk visits the browser's own toolbar, tab strip, and bookmarks
    /// with one cross-process call per node, which every 2-second detector
    /// tick used to repeat for every window, in LokalBot and in the browser.
    final class QuietWindowCache: @unchecked Sendable {
        static let maximumAge: TimeInterval = 30

        private struct Entry {
            let window: AXUIElement
            let title: String
            let checkedAt: TimeInterval
        }

        private let lock = NSLock()
        private var entries: [pid_t: [Entry]] = [:]

        func isQuiet(_ window: AXUIElement, title: String, processID: pid_t, now: TimeInterval) -> Bool {
            lock.withLock {
                entries[processID]?.contains {
                    CFEqual($0.window, window) && $0.title == title && now - $0.checkedAt < Self.maximumAge
                } ?? false
            }
        }

        func record(_ window: AXUIElement, title: String, quiet: Bool, processID: pid_t, now: TimeInterval) {
            lock.withLock {
                var list = entries[processID, default: []].filter { !CFEqual($0.window, window) }
                if quiet { list.append(Entry(window: window, title: title, checkedAt: now)) }
                entries[processID] = list.isEmpty ? nil : list
            }
        }

        /// Forgets windows that closed.
        func keep(only windows: [AXUIElement], processID: pid_t) {
            lock.withLock {
                guard let list = entries[processID] else { return }
                let kept = list.filter { entry in windows.contains { CFEqual($0, entry.window) } }
                entries[processID] = kept.isEmpty ? nil : kept
            }
        }

        func removeAll() {
            lock.withLock { entries.removeAll() }
        }
    }
    static let quietWindows = QuietWindowCache()

    private final class PrimedProcesses: @unchecked Sendable {
        private let lock = NSLock()
        private var processes: Set<pid_t> = []

        func contains(_ pid: pid_t) -> Bool { lock.withLock { processes.contains(pid) } }
        func insert(_ pid: pid_t) { _ = lock.withLock { processes.insert(pid) } }
    }
    private static let primedProcesses = PrimedProcesses()

    /// Chromium and Firefox expose page content to accessibility clients only
    /// once asked. Ask once per browser process. Chromium honours
    /// `AXManualAccessibility`, the switch meant for assistive tools that are
    /// not screen readers (cotyping already uses it). `AXEnhancedUserInterface`
    /// also puts the whole app into VoiceOver mode, which slows Chrome and
    /// breaks window-manager animations, and it used to be set on every
    /// 2-second poll; only Firefox still needs it. Safari exposes its pages.
    static func webAccessibilityPrimingAttribute(bundleID: String?) -> String? {
        switch bundleID {
        case "org.mozilla.firefox": "AXEnhancedUserInterface"
        case "com.apple.Safari", nil: nil
        default: "AXManualAccessibility"
        }
    }

    private static func primeWebAccessibility(_ app: AXUIElement, processID: pid_t, bundleID: String?) {
        guard !primedProcesses.contains(processID) else { return }
        guard let attribute = webAccessibilityPrimingAttribute(bundleID: bundleID) else {
            primedProcesses.insert(processID)
            return
        }
        switch AXUIElementSetAttributeValue(app, attribute as CFString, kCFBooleanTrue) {
        case .success, .attributeUnsupported:
            primedProcesses.insert(processID)
        default:
            // A busy browser timed out; ask again on the next poll.
            break
        }
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
    }

    private static func fields(_ element: AXUIElement) -> [String: AnyObject]? {
        let keys = [kAXRoleAttribute, kAXURLAttribute, kAXChildrenAttribute, kAXTitleAttribute,
                    kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute, kAXSelectedAttribute,
                    kAXEnabledAttribute, "AXHidden"]
        var result: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, keys as CFArray,
                AXCopyMultipleAttributeOptions(rawValue: 0), &result) == .success,
              let values = result as? [AnyObject], values.count == keys.count else { return nil }
        return Dictionary(uniqueKeysWithValues: zip(keys, values))
    }
}
