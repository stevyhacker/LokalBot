import AppKit
import ApplicationServices
import Foundation

struct MeetingParticipantTile: Equatable, Sendable {
    var name: String
    var frame: CGRect
    var speaking: Bool?
    var muted: Bool
    var isSelf: Bool
    var sharedRoom = false
    var requiresNameVerification = false
    var activityIndicatorFrame: CGRect?
}

struct MeetingParticipantSnapshot: Sendable {
    var processID: pid_t
    var title: String
    var url: String
    var windowFrame: CGRect
    var tiles: [MeetingParticipantTile]
    var hostStart: Double
    var hostEnd: Double
    var otherAudibleTabs = false
    var selfNames: [String] = []
}

struct MeetingParticipantCaptureResult: Sendable {
    var snapshot: MeetingParticipantSnapshot?
    var issue: SpeakerObservationIssue?
    static func unavailable(_ issue: SpeakerObservationIssue) -> Self { .init(issue: issue) }
}

/// One bounded worker; batch AX attributes to avoid an IPC for every field.
/// Only the selected Meet document supplies participant identities. Embedded
/// documents (including presentations) are never scanned for speaker names.
final class MeetingParticipantAccessibilityReader: @unchecked Sendable {
    static let observationBudget = 0.30
    private let queue = DispatchQueue(label: "lokalbot.meeting-speaker.ax", qos: .utility)
    private let lock = NSLock()
    private var busy = false
    // Confined to queue. Losing this window must never bind a different profile.
    private var boundWindow: AXUIElement?
    private func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !busy else { return false }
        busy = true
        return true
    }
    private func release() { lock.lock(); busy = false; lock.unlock() }

    func capture(processID: pid_t, expectedURL: URL? = nil) async -> MeetingParticipantCaptureResult {
        guard AXIsProcessTrusted() else { return .unavailable(.accessibilityPermission) }
        guard claim() else { return .unavailable(.accessibilityBusy) }
        return await withCheckedContinuation { continuation in
            let delivery = Delivery(continuation)
            queue.async { [self] in
                let result = Self.resolve(processID, expectedURL: expectedURL, boundWindow: &boundWindow)
                release()
                delivery.finish(result)
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.65) {
                delivery.finish(.unavailable(.accessibilityTimeout))
            }
        }
    }

    private final class Delivery: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<MeetingParticipantCaptureResult, Never>?
        init(_ continuation: CheckedContinuation<MeetingParticipantCaptureResult, Never>) { self.continuation = continuation }
        func finish(_ value: MeetingParticipantCaptureResult) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
    }
    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let result = value(parent, attribute), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }

    private struct Fields {
        var values: [String: AnyObject]
        var depth: Int
        func string(_ key: String) -> String { values[key] as? String ?? "" }
        var labels: [String] {
            [kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute, kAXHelpAttribute].map(string).filter { !$0.isEmpty }
        }
        var children: [AXUIElement] { values[kAXChildrenAttribute] as? [AXUIElement] ?? [] }
        var frame: CGRect? {
            guard let position = values[kAXPositionAttribute], CFGetTypeID(position) == AXValueGetTypeID(),
                  let size = values[kAXSizeAttribute], CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
            var point = CGPoint.zero
            var dimensions = CGSize.zero
            guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
                  AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
                  dimensions.width.isFinite, dimensions.height.isFinite,
                  dimensions.width > 0, dimensions.height > 0 else { return nil }
            return CGRect(origin: point, size: dimensions)
        }
    }

    private static func fields(_ node: AXUIElement, depth: Int) -> Fields? {
        let attributes = [kAXRoleAttribute, kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute,
                          kAXHelpAttribute, kAXChildrenAttribute, kAXPositionAttribute, kAXSizeAttribute,
                          kAXURLAttribute, kAXDocumentAttribute, kAXSelectedAttribute, "AXHidden"]
        var output: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(node, attributes as CFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0), &output) == .success,
              let values = output as? [AnyObject], values.count == attributes.count else { return nil }
        return Fields(values: Dictionary(uniqueKeysWithValues: zip(attributes, values)), depth: depth)
    }

    static func tileName(description: String) -> String? {
        for suffix in ["'s tile", "’s tile", "'s video", "’s video"] where description.hasSuffix(suffix) {
            return ParticipantObservation.safeName(String(description.dropLast(suffix.count)))
        }
        for prefix in ["Video of ", "Tile of ", "Participant: "] where description.hasPrefix(prefix) {
            return ParticipantObservation.safeName(String(description.dropFirst(prefix.count)))
        }
        return nil
    }

    private static func resolve(_ processID: pid_t, expectedURL: URL?, boundWindow: inout AXUIElement?) -> MeetingParticipantCaptureResult {
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 0.012)
        // Chromium may expose only its browser chrome until an AX client asks
        // for the web tree. This does not grant or prompt for TCC permission.
        AXUIElementSetAttributeValue(application, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        if boundWindow == nil {
            boundWindow = BrowserMeetingSession.window(processID: processID, expectedURL: expectedURL, preferFocused: true)?.element
        }
        guard let window = boundWindow,
              let available = value(application, kAXWindowsAttribute) as? [AXUIElement],
              available.contains(where: { CFEqual(window, $0) }) else { return .unavailable(.sourceUnavailable) }
        let start = RecordingAudioClock.now
        guard
              (value(window, kAXMinimizedAttribute) as? Bool) != true,
              let windowFields = fields(window, depth: 0), let frame = windowFields.frame else { return .unavailable(.sourceUnavailable) }
        let title = windowFields.string(kAXTitleAttribute)
        guard !ScreenContextPrivacy.isPrivateWindow(title: title) else { return .unavailable(.sourceRejected) }
        if let focused = element(application, kAXFocusedUIElementAttribute),
           (value(focused, kAXSubroleAttribute) as? String) == "AXSecureTextField" { return .unavailable(.sourceRejected) }
        var stack: [(AXUIElement, Int, Bool)] = [(window, 0, false)]
        var count = 0
        var selectedURL: String?
        var records: [Fields] = []
        var otherAudibleTabs = false
        while let (node, depth, insideMeet) = stack.popLast() {
            count += 1
            guard count <= 1_500, RecordingAudioClock.now - start <= observationBudget else { return .unavailable(.accessibilityBudget) }
            guard let item = fields(node, depth: depth) else { return .unavailable(.sourceUnavailable) }
            if item.values["AXHidden"] as? Bool == true { continue }
            let role = item.string(kAXRoleAttribute)
            var inDocument = insideMeet
            if role == "AXWebArea" {
                if insideMeet { continue } // Never read an embedded presentation/third-party frame.
                let raw = item.values[kAXURLAttribute]
                let url = (raw as? URL)?.absoluteString ?? (raw as? String) ?? item.string(kAXDocumentAttribute)
                guard selectedURL == nil, let valid = GoogleMeetSpeakerObservationProvider.meetURL(url),
                      expectedURL == nil || GoogleMeetSpeakerObservationProvider.meetURL(expectedURL!.absoluteString) == valid
                else { return .unavailable(.sourceUnavailable) }
                selectedURL = valid
                inDocument = true
            }
            if ["AXRadioButton", "AXTab"].contains(role),
               item.labels.contains(where: { $0.localizedCaseInsensitiveContains("audio playing") }),
               item.values[kAXSelectedAttribute] as? Bool != true { otherAudibleTabs = true }
            if inDocument { records.append(item) }
            let children = item.children
            guard children.count <= 300, depth < 30 || children.isEmpty else { return .unavailable(.accessibilityBudget) }
            stack += children.reversed().map { ($0, depth + 1, inDocument) }
        }
        guard let url = selectedURL,
              let windows = value(application, kAXWindowsAttribute) as? [AXUIElement], windows.contains(where: { CFEqual(window, $0) }) else { return .unavailable(.sourceChanged) }
        var tiles: [MeetingParticipantTile] = []
        var selfNames = Set<String>()
        var indicators: [String: [CGRect]] = [:]
        for (index, item) in records.enumerated() where item.labels.contains("Participants") {
            for (offset, child) in records.dropFirst(index + 1).prefix(500).enumerated() {
                if child.depth <= item.depth { break }
                for label in child.labels {
                    if let name = MeetingParticipantTileResolver.selfName(label) { selfNames.insert(name) }
                }
                guard child.string(kAXRoleAttribute) == "AXGroup" else { continue }
                var rowLabels: [String] = []
                for nested in records.dropFirst(index + offset + 2).prefix(30) {
                    if nested.depth <= child.depth { break }
                    rowLabels += nested.labels
                }
                if let name = MeetingParticipantTileResolver.selfName(rowLabels: child.labels, descendantLabels: rowLabels) {
                    selfNames.insert(name)
                }
                let rowNames = Set(child.labels.compactMap(ParticipantObservation.safeName))
                if rowNames.count == 1, let name = rowNames.first {
                    for nested in records.dropFirst(index + offset + 2).prefix(30) {
                        if nested.depth <= child.depth { break }
                        if nested.labels.contains("Mute \(name)'s microphone"), let rect = nested.frame {
                            indicators[ParticipantObservation.nameKey(name), default: []].append(rect)
                        }
                    }
                }
            }
        }
        let excludedRegions = records.filter {
            $0.labels.contains { ["Side panel", "Left side panel", "Call controls"].contains($0) }
        }.compactMap(\.frame)
        for (index, item) in records.enumerated() {
            guard ["AXGroup", "AXImage", "AXUnknown"].contains(item.string(kAXRoleAttribute)),
                  let tileFrame = item.frame, frame.contains(tileFrame),
                  tileFrame.width >= 80, tileFrame.height >= 60,
                  !excludedRegions.contains(where: { $0.contains(tileFrame) }) else { continue }
            var labels: [String] = []
            var visibleLabels: [MeetingParticipantTileResolver.VisibleLabel] = []
            for child in records.dropFirst(index + 1).prefix(100) {
                if child.depth <= item.depth { break }
                if child.depth <= item.depth + 6 {
                    labels += child.labels
                    if child.string(kAXRoleAttribute) == "AXStaticText", let textFrame = child.frame,
                       let text = child.labels.first {
                        visibleLabels.append(.init(text: text, frame: textFrame))
                    }
                }
            }
            let structured = MeetingParticipantTileResolver.name(ownLabels: item.labels, descendantLabels: labels)
            guard let name = structured ?? MeetingParticipantTileResolver.nameStrip(frame: tileFrame,
                labels: visibleLabels, controls: item.labels + labels) else { continue }
            var tile = MeetingParticipantTileResolver.tile(name: name, frame: tileFrame, labels: item.labels + labels)
            tile.requiresNameVerification = structured == nil
            tile.isSelf = tile.isSelf || selfNames.contains { ParticipantObservation.nameKey($0) == ParticipantObservation.nameKey(name) }
            if let matches = indicators[ParticipantObservation.nameKey(name)], matches.count == 1 {
                tile.activityIndicatorFrame = matches.first
            }
            tiles.append(tile)
        }
        guard RecordingAudioClock.now - start <= observationBudget else { return .unavailable(.accessibilityBudget) }
        return .init(snapshot: MeetingParticipantSnapshot(processID: processID, title: title, url: url, windowFrame: frame,
            tiles: MeetingParticipantTileResolver.innermostTiles(tiles), hostStart: start,
            hostEnd: RecordingAudioClock.now, otherAudibleTabs: otherAudibleTabs, selfNames: selfNames.sorted()))
    }
}
