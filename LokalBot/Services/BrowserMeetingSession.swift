import AppKit
import ApplicationServices

/// Call lifecycle evidence is independent of audio and experimental speaker
/// observation. Only a supported meeting document and its call controls count.
enum BrowserMeetingSession {
    enum State: Equatable { case inCall, ended, unavailable }
    struct Snapshot: Equatable {
        var url: URL
        var state: State
    }
    struct Window {
        var element: AXUIElement
        var snapshot: Snapshot
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

    static func state(buttons: [String], messages: [String]) -> State {
        let buttons = buttons.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        let ended = messages.contains {
            ["you left the meeting", "you've left the meeting", "you have left the meeting",
             "you were removed from the meeting", "the meeting has ended"].contains($0.lowercased())
        }
        if ended { return .ended }
        let leave = buttons.contains { $0 == "leave call" || $0 == "leave meeting" || $0 == "hang up" }
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
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        let expected = expectedURL.flatMap { GoogleMeetSpeakerObservationProvider.meetURL($0.absoluteString) }
        guard expectedURL == nil || expected != nil,
              let windows = value(app, kAXWindowsAttribute) as? [AXUIElement], windows.count <= 32 else { return nil }
        var matches: [Window] = []
        var count = 0
        var conflictingAudio = false
        for window in windows {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            let title = value(window, kAXTitleAttribute) as? String ?? ""
            if ScreenContextPrivacy.isPrivateWindow(title: title)
                || value(window, kAXMinimizedAttribute) as? Bool == true { continue }
            var stack: [(AXUIElement, Int, Bool)] = [(window, 0, false)]
            var url: String?
            var buttons: [String] = []
            var messages: [String] = []
            var audibleTabs: [Bool] = []
            while let (node, depth, inside) = stack.popLast() {
                count += 1
                guard count <= 3_000, depth <= 30, ProcessInfo.processInfo.systemUptime < deadline else { return nil }
                guard let fields = fields(node) else { return nil }
                if fields["AXHidden"] as? Bool == true { continue }
                let role = fields[kAXRoleAttribute] as? String ?? ""
                if ["AXRadioButton", "AXTab"].contains(role) {
                    let labels = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
                        .compactMap { fields[$0] as? String }
                    if labels.contains(where: { $0.localizedCaseInsensitiveContains("audio playing") }) {
                        audibleTabs.append(fields[kAXSelectedAttribute] as? Bool == true)
                    }
                }
                var inDocument = inside
                if role == "AXWebArea" {
                    if inside { continue }
                    let raw = fields[kAXURLAttribute]
                    let text = (raw as? URL)?.absoluteString ?? (raw as? String) ?? ""
                    guard let valid = GoogleMeetSpeakerObservationProvider.meetURL(text),
                          expected == nil || valid == expected else { continue }
                    guard url == nil else { return nil }
                    url = valid
                    inDocument = true
                }
                if inDocument && ["AXButton", "AXStaticText", "AXHeading"].contains(role) {
                    let labels = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
                        .compactMap { fields[$0] as? String }.filter { $0.count <= 160 }
                    if role == "AXButton" { buttons += labels } else { messages += labels }
                }
                let children = fields[kAXChildrenAttribute] as? [AXUIElement] ?? []
                guard children.count <= 500 else { return nil }
                stack += children.reversed().map { ($0, depth + 1, inDocument) }
            }
            if let url, let parsed = URL(string: url) {
                matches.append(Window(element: window, snapshot: Snapshot(url: parsed, state: state(buttons: buttons, messages: messages))))
            }
            conflictingAudio = conflictingAudio || hasConflictingAudio(selectedAudibleTabs: audibleTabs, hasBoundDocument: url != nil)
        }
        if conflictingAudio {
            for index in matches.indices { matches[index].snapshot.state = .unavailable }
        }
        // Multiple unrelated Meet windows cannot silently pick the first call.
        if expected == nil {
            let calls = matches.filter { $0.snapshot.state == .inCall }
            return calls.count == 1 ? calls.first : nil
        }
        return matches.count == 1 ? matches.first : nil
    }

    static func hasConflictingAudio(selectedAudibleTabs: [Bool], hasBoundDocument: Bool) -> Bool {
        !selectedAudibleTabs.isEmpty && (!hasBoundDocument || selectedAudibleTabs.contains(false) || selectedAudibleTabs.count > 1)
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
