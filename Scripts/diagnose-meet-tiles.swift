// diagnose-meet-tiles.swift
//
// Read-only local diagnostic for LokalBot's Google Meet speaker observation.
// It replays the app's Accessibility discovery
// (MeetingParticipantAccessibilityReader + MeetingParticipantTileResolver +
// BrowserMeetingSession lifecycle labels) and dumps what the Meet AX tree
// actually exposes right now: document URLs, tile candidates, resolved names,
// speaking/muted labels, and unmatched groups. No pixels, no ScreenCaptureKit,
// no network. Output stays in the local file you choose (default /tmp).
// Persistent name-strip candidates are reported separately: the app must still
// corroborate them with OCR before retaining them as participant suggestions.
//
// WARNING: the output contains participant names from your live meeting.
// Keep it local and delete it when done.
//
// Build: swiftc -o /tmp/meet-ax-dump Scripts/diagnose-meet-tiles.swift
// Run (while a Meet call is live in Chrome, Meet tab selected):
//   /tmp/meet-ax-dump [--expected-url https://meet.google.com/xxx-xxxx-xxx]
//                     [--output /tmp/lokalbot-meet-ax-dump.json]
//                     [--max-nodes 5000] [--window-budget 2.0]
//
// The terminal running this needs Accessibility permission
// (System Settings -> Privacy & Security -> Accessibility). Without it the
// tool reports untrusted and exits, same as the app's
// .accessibilityPermission path.

import AppKit
import ApplicationServices
import Foundation

struct DumpConfig {
    var expectedURL: String?
    var output: String = "/tmp/lokalbot-meet-ax-dump.json"
    var maxNodes = 5_000
    var windowBudget: Double = 2.0
}

func parseArgs() -> DumpConfig {
    var config = DumpConfig()
    var index = 1
    let args = CommandLine.arguments
    while index < args.count {
        let arg = args[index]
        func next() -> String? {
            guard index + 1 < args.count else { return nil }
            index += 1
            return args[index]
        }
        switch arg {
        case "--expected-url": config.expectedURL = next()
        case "--output": if let v = next() { config.output = v }
        case "--max-nodes": if let v = next(), let n = Int(v) { config.maxNodes = n }
        case "--window-budget": if let v = next(), let d = Double(v) { config.windowBudget = d }
        case "-h", "--help":
            print("usage: meet-ax-dump [--expected-url <meet url>] [--output <path>] [--max-nodes N] [--window-budget S]")
            exit(0)
        default:
            fputs("Unknown argument: \(arg)\n", stderr)
            exit(64)
        }
        index += 1
    }
    return config
}

// MARK: - Meet URL (mirrors GoogleMeetSpeakerObservationProvider.meetURL)

func meetURL(_ raw: String) -> String? {
    guard let components = URLComponents(string: raw),
          components.scheme == "https",
          components.host?.lowercased() == "meet.google.com",
          components.user == nil, components.password == nil,
          components.port == nil || components.port == 443,
          components.path.range(of: #"^/[a-z]{3}-[a-z]{4}-[a-z]{3}$"#,
                                options: .regularExpression) != nil
    else { return nil }
    return "https://meet.google.com" + components.path
}

// MARK: - AX helpers

let axKeys = [kAXRoleAttribute, kAXDescriptionAttribute, kAXTitleAttribute,
              kAXValueAttribute, kAXHelpAttribute, kAXChildrenAttribute,
              kAXPositionAttribute, kAXSizeAttribute, kAXURLAttribute,
              kAXDocumentAttribute, kAXSelectedAttribute, "AXHidden"] as [String]

func axFields(_ node: AXUIElement) -> [String: AnyObject]? {
    var output: CFArray?
    guard AXUIElementCopyMultipleAttributeValues(node, axKeys as CFArray,
        AXCopyMultipleAttributeOptions(rawValue: 0), &output) == .success,
        let values = output as? [AnyObject], values.count == axKeys.count
    else { return nil }
    return Dictionary(uniqueKeysWithValues: zip(axKeys, values))
}

func axString(_ fields: [String: AnyObject], _ key: String) -> String {
    fields[key] as? String ?? ""
}

func axFrame(_ fields: [String: AnyObject]) -> CGRect? {
    guard let position = fields[kAXPositionAttribute],
          CFGetTypeID(position) == AXValueGetTypeID(),
          let size = fields[kAXSizeAttribute],
          CFGetTypeID(size) == AXValueGetTypeID()
    else { return nil }
    var point = CGPoint.zero
    var dimensions = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
          AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
          dimensions.width.isFinite, dimensions.height.isFinite,
          dimensions.width > 0, dimensions.height > 0
    else { return nil }
    return CGRect(origin: point, size: dimensions)
}

// Single-attribute fallback: the app's 12-attribute batch read aborts the
// whole scan when ANY node rejects it ( surfacing as sourceUnavailable ).
// The diagnostic must not share that brittleness, so fall back to reading
// one attribute at a time and keep walking.
func axSingle(_ node: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var result: CFTypeRef?
    return AXUIElementCopyAttributeValue(node, attribute as CFString,
                                         &result) == .success ? result : nil
}

func axFallbackFields(_ node: AXUIElement) -> [String: AnyObject]? {
    var out: [String: AnyObject] = [:]
    for key in axKeys {
        if let value = axSingle(node, key) {
            out[key] = value
        }
    }
    // A node that answers nothing at all is genuinely unreadable.
    guard out[kAXRoleAttribute] as? String != nil
        || out[kAXChildrenAttribute] != nil
    else { return nil }
    return out
}

func tolerantFields(_ node: AXUIElement, fallbackUsed: inout Bool)
    -> [String: AnyObject]?
{
    if let fields = axFields(node) { return fields }
    fallbackUsed = true
    return axFallbackFields(node)
}

func frameString(_ frame: CGRect) -> String {
    String(format: "(%.0f,%.0f,%.0fx%.0f)",
           frame.minX, frame.minY, frame.width, frame.height)
}

// MARK: - Tile-name logic (mirrors MeetingParticipantTileResolver)

func basicSafeName(_ raw: String) -> String? {
    let name = raw.replacingOccurrences(of: #"\s+"#, with: " ",
                                        options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard (2...80).contains(name.count), !name.contains("@"),
          !name.contains("://"),
          !["you", "presentation", "presenting", "everyone",
             "shared room"].contains(name.lowercased())
    else { return nil }
    return name
}

func tileName(description: String) -> String? {
    for suffix in ["'s tile", "'s tile", "'s video", "'s video"]
        where description.hasSuffix(suffix)
    {
        return basicSafeName(String(description.dropLast(suffix.count)))
    }
    for prefix in ["Video of ", "Tile of ", "Participant: "]
        where description.hasPrefix(prefix)
    {
        return basicSafeName(String(description.dropFirst(prefix.count)))
    }
    return nil
}

func resolveName(ownLabels: [String], descendantLabels: [String]) -> String? {
    let direct = Set(ownLabels.compactMap { tileName(description: $0) })
    if direct.count == 1 { return direct.first }
    guard direct.isEmpty else { return nil } // conflicting direct names
    let labels = Set((ownLabels + descendantLabels).map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }.filter { !$0.isEmpty })
    var names = Set<String>()
    for label in labels {
        var candidate: String?
        for prefix in ["More options for ", "Mute ", "Pin ", "Unpin "]
            where label.hasPrefix(prefix)
        {
            candidate = String(label.dropFirst(prefix.count))
            for suffix in [" to your main screen", " from your main screen",
                           " for everyone"]
            {
                if candidate?.hasSuffix(suffix) == true {
                    candidate = String(candidate!.dropLast(suffix.count))
                }
            }
        }
        guard let candidate, let name = basicSafeName(candidate),
              labels.contains(name) || labels.contains(name + " (You)")
                || labels.contains(name + " (you)")
        else { continue }
        names.insert(name)
    }
    return names.count == 1 ? names.first : nil
}

struct TileFlags {
    var speaking: Bool?
    var muted: Bool
    var isSelf: Bool
}

func tileFlags(name: String, labels: [String]) -> TileFlags {
    let keys = Set(labels.map { $0.lowercased() })
    let key = name.lowercased()
    let speaking = keys.contains("\(key) is speaking")
        || keys.contains("speaking: \(key)") || keys.contains("speaking")
    let silent = keys.contains("\(key) is not speaking")
        || keys.contains("not speaking")
    return TileFlags(
        speaking: speaking && !silent ? true : silent ? false : nil,
        muted: keys.contains("\(key)'s microphone is off")
            || keys.contains("microphone off")
            || keys.contains("microphone is off"),
        isSelf: keys.contains("your tile") || keys.contains("you")
            || keys.contains("\(key) (you)") || keys.contains("reframe")
            || keys.contains("backgrounds and effects")
            || keys.contains("others might see more of your background. click to view your full video."))
}

func persistentName(frame: CGRect, labels: [(text: String, frame: CGRect)], controls: [String]) -> String? {
    guard frame.width >= 120, frame.height >= 90,
          !controls.contains(where: {
              let key = $0.lowercased()
              return key.contains("presenting") || key.contains("presentation")
                || ["call controls", "side panel", "participants", "in the meeting", "leave call", "chat with everyone"].contains(key)
          }) else { return nil }
    let visible = labels.filter { frame.contains($0.frame) }
    let names = Set(visible.compactMap { label -> String? in
        guard label.frame.minY >= frame.minY + frame.height * 0.75,
              label.frame.minX <= frame.minX + min(80, frame.width * 0.25),
              label.frame.height <= 40, label.frame.width < frame.width * 0.85,
              let name = basicSafeName(label.text), name.rangeOfCharacter(from: .letters) != nil else { return nil }
        return name
    })
    guard names.count == 1, visible.filter({ $0.text.count > 1 }).count == 1 else { return nil }
    return names.first
}

// MARK: - Window scan

struct Record {
    var role: String
    var depth: Int
    var frame: CGRect?
    var labels: [String]
}

func scanWindow(_ window: AXUIElement, config: DumpConfig)
    -> (title: String, frame: CGRect?, url: String?, records: [Record],
        buttons: [String], messages: [String], otherAudibleTabs: Bool,
        truncated: Bool, fallbackUsed: Bool, error: String?)
{
    var fallbackUsed = false
    guard let top = tolerantFields(window, fallbackUsed: &fallbackUsed)
    else {
        return ("", nil, nil, [], [], [], false, true, fallbackUsed,
                "window-attributes-unreadable")
    }
    let title = axString(top, kAXTitleAttribute)
    let frame = axFrame(top)
    var records: [Record] = []
    var buttons: [String] = []
    var messages: [String] = []
    var otherAudibleTabs = false
    var selectedURL: String?
    var count = 0
    var truncated = false
    var error: String?
    let deadline = ProcessInfo.processInfo.systemUptime + config.windowBudget
    var stack: [(AXUIElement, Int, Bool)] = [(window, 0, false)]
    while let (node, depth, insideMeet) = stack.popLast() {
        count += 1
        if count > config.maxNodes
            || ProcessInfo.processInfo.systemUptime >= deadline
        {
            truncated = true
            break
        }
        guard let item = tolerantFields(node, fallbackUsed: &fallbackUsed)
        else {
            if error == nil { error = "node-attributes-unreadable" }
            continue
        }
        if item["AXHidden"] as? Bool == true { continue }
        let role = axString(item, kAXRoleAttribute)
        var inDocument = insideMeet
        if role == "AXWebArea" {
            if insideMeet { continue }
            let raw = item[kAXURLAttribute]
            let url = (raw as? URL)?.absoluteString ?? (raw as? String) ?? ""
            if let valid = meetURL(url) {
                if selectedURL == nil {
                    selectedURL = valid
                    inDocument = true
                }
            } else if selectedURL == nil {
                // Non-Meet document; keep walking in case a Meet
                // document exists elsewhere in this window.
                inDocument = false
            }
        }
        let labels = [kAXDescriptionAttribute, kAXTitleAttribute,
                      kAXValueAttribute, kAXHelpAttribute]
            .map { axString(item, $0) }.filter { !$0.isEmpty }
        if ["AXRadioButton", "AXTab"].contains(role),
           labels.contains(where: {
               $0.localizedCaseInsensitiveContains("audio playing")
           }),
           item[kAXSelectedAttribute] as? Bool != true
        {
            otherAudibleTabs = true
        }
        if inDocument {
            records.append(Record(role: role, depth: depth,
                                  frame: axFrame(item), labels: labels))
            if ["AXButton", "AXStaticText", "AXHeading"].contains(role) {
                let short = labels.filter { $0.count <= 160 }
                if role == "AXButton" { buttons += short }
                else { messages += short }
            }
        }
        let children =
            (item[kAXChildrenAttribute] as? [AXUIElement]) ?? []
        guard children.count <= 500 else {
            truncated = true
            if error == nil { error = "children-over-budget" }
            continue
        }
        stack += children.reversed().map { ($0, depth + 1, inDocument) }
    }
    return (title, frame, selectedURL, records, buttons, messages,
            otherAudibleTabs, truncated, fallbackUsed, error)
}

// MARK: - Main

let config = parseArgs()
var diagnosis: [String] = []

guard AXIsProcessTrusted() else {
    print("AX untrusted: grant Accessibility to this terminal, then re-run.")
    print("System Settings -> Privacy & Security -> Accessibility")
    exit(3)
}

let chromes = NSRunningApplication.runningApplications(
    withBundleIdentifier: "com.google.Chrome")
print("Chrome instances: \(chromes.count)")
if chromes.count != 1 {
    diagnosis.append(
        "App requires exactly 1 Chrome instance; found \(chromes.count).")
}
guard let chrome = chromes.first else {
    print("No running Chrome. Open the Meet call in Chrome and re-run.")
    exit(4)
}

let appElement = AXUIElementCreateApplication(chrome.processIdentifier)
AXUIElementSetMessagingTimeout(appElement, 0.012)
AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString,
                              kCFBooleanTrue)
var windowRefs: CFTypeRef?
guard AXUIElementCopyAttributeValue(appElement,
                                    kAXWindowsAttribute as CFString,
                                    &windowRefs) == .success,
    let windows = windowRefs as? [AXUIElement]
else {
    print("Could not list Chrome windows via AX.")
    exit(5)
}
print("Chrome AX windows: \(windows.count)")

var windowDumps: [[String: Any]] = []
var meetWindows = 0
var totalTiles = 0
var totalNamed = 0
var totalSpeakingLabels = 0
var totalPersistent = 0

for (wIndex, window) in windows.enumerated() {
    let scan = scanWindow(window, config: config)
    let url = scan.url
    if let expected = config.expectedURL.flatMap(meetURL),
       let found = url, found != expected
    {
        continue // not the bound meeting
    }
    if url != nil { meetWindows += 1 }
    let groupRoles = Set(scan.records.map(\.role)).sorted()

    // Tile candidates: same role/size filter as the app.
    var candidates: [(frame: CGRect, own: [String], desc: [String], visible: [(text: String, frame: CGRect)])] = []
    let excludedRegions = scan.records.filter {
        $0.labels.contains { ["Side panel", "Left side panel", "Call controls"].contains($0) }
    }.compactMap(\.frame)
    for (index, record) in scan.records.enumerated()
        where ["AXGroup", "AXImage", "AXUnknown"].contains(record.role)
    {
        guard let tileFrame = record.frame,
              let windowFrame = scan.frame,
              windowFrame.contains(tileFrame),
              tileFrame.width >= 80, tileFrame.height >= 60,
              !excludedRegions.contains(where: { $0.contains(tileFrame) })
        else { continue }
        var desc: [String] = []
        var visible: [(text: String, frame: CGRect)] = []
        for child in scan.records.dropFirst(index + 1).prefix(100) {
            if child.depth <= record.depth { break }
            if child.depth <= record.depth + 6 {
                desc += child.labels
                if child.role == "AXStaticText", let textFrame = child.frame, let text = child.labels.first {
                    visible.append((text, textFrame))
                }
            }
        }
        candidates.append((tileFrame, record.labels, desc, visible))
    }
    // Innermost dedupe mirrors the app (smallest frame wins per name).
    var tiles: [[String: Any]] = []
    var unmatched: [[String: Any]] = []
    var persistent: [[String: Any]] = []
    for candidate in candidates.sorted(by: {
        $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
    }) {
        let name = resolveName(ownLabels: candidate.own,
                               descendantLabels: candidate.desc)
        if let name {
            if tiles.contains(where: {
                ($0["name"] as? String)?.lowercased() == name.lowercased()
            }) { continue }
            let flags = tileFlags(name: name,
                                  labels: candidate.own + candidate.desc)
            if flags.speaking == true { totalSpeakingLabels += 1 }
            tiles.append([
                "name": name,
                "frame": frameString(candidate.frame),
                "speaking": flags.speaking as Any,
                "muted": flags.muted,
                "isSelf": flags.isSelf,
                "ownLabels": candidate.own,
                "descendantLabelCount": candidate.desc.count,
                "descendantLabels": Array(candidate.desc.prefix(20)),
            ])
        } else {
            if let name = persistentName(frame: candidate.frame, labels: candidate.visible, controls: candidate.own + candidate.desc),
               !persistent.contains(where: { $0["name"] as? String == name }) {
                persistent.append(["name": name, "frame": frameString(candidate.frame), "requiresOCR": true])
            }
            if unmatched.count < 100 {
                unmatched.append([
                    "role": "tile-candidate",
                    "frame": frameString(candidate.frame),
                    "ownLabels": candidate.own,
                    "descendantLabels": Array(candidate.desc.prefix(20)),
                ])
            }
        }
    }
    totalTiles += candidates.count
    totalNamed += tiles.count
    totalPersistent += persistent.count

    windowDumps.append([
        "index": wIndex,
        "title": scan.title,
        "frame": scan.frame.map(frameString) as Any,
        "meetURL": url as Any,
        "otherAudibleTabs": scan.otherAudibleTabs,
        "truncated": scan.truncated,
        "axBatchFallbackUsed": scan.fallbackUsed,
        "axError": scan.error as Any,
        "axNodeCount": scan.records.count,
        "roles": groupRoles,
        "tileCandidates": candidates.count,
        "namedTiles": tiles,
        "persistentNameCandidates": persistent,
        "unmatchedCandidates": unmatched,
        "buttons": Array(Set(scan.buttons).sorted().prefix(60)),
        "messages": Array(Set(scan.messages).sorted().prefix(60)),
    ])
}

print("Meet documents found: \(meetWindows)")
print("Tile candidates: \(totalTiles), named: \(totalNamed), "
    + "with speaking label: \(totalSpeakingLabels)")
print("Persistent name candidates needing OCR: \(totalPersistent)")

if meetWindows == 0 {
    diagnosis.append("No Meet AXWebArea found: app reports sourceUnavailable. "
        + "Keep the Meet tab selected in that Chrome window.")
} else if totalTiles == 0 {
    diagnosis.append("Meet document readable but zero tile candidates: app "
        + "reports layoutUnavailable. Inspect roles/unmatchedCandidates: the "
        + "current Meet layout likely uses roles or label patterns outside "
        + "AXGroup/AXImage/AXUnknown + \"X's tile\" / \"Video of X\" / "
        + "\"More options for X\".")
} else if totalPersistent > 0 {
    diagnosis.append("Persistent tile names are available without hover controls. The app corroborates these with local OCR; this AX-only diagnostic does not verify pixels or speaking activity.")
} else if totalNamed == 0 {
    diagnosis.append("Tile-size groups exist but no names resolved: compare "
        + "ownLabels/descendantLabels against the accepted patterns.")
} else if totalSpeakingLabels == 0 {
    diagnosis.append("Names resolve but no speaking labels: app falls back to "
        + "the ScreenCaptureKit frame path, which needs Screen Recording "
        + "permission and a fresh frame within 0.75s.")
}

let output: [String: Any] = [
    "generatedAt": ISO8601DateFormatter().string(from: Date()),
    "chromeInstances": chromes.count,
    "meetWindows": meetWindows,
    "tileCandidates": totalTiles,
    "namedTiles": totalNamed,
    "speakingLabels": totalSpeakingLabels,
    "persistentNameCandidates": totalPersistent,
    "diagnosis": diagnosis,
    "windows": windowDumps,
]
do {
    let data = try JSONSerialization.data(
        withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: URL(fileURLWithPath: config.output), options: .atomic)
    print("Wrote \(config.output) (\(data.count) bytes)")
} catch {
    fputs("Write failed: \(error)\n", stderr)
    exit(1)
}
for line in diagnosis { print("- " + line) }
