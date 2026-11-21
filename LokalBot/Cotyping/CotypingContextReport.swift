import CoreGraphics
import Foundation

struct CotypingContextAvailability: Equatable, Sendable {
    struct Inventory: Equatable, Sendable {
        var libraryReady = true
        var recentMeetings = 0
        var meetingFacts = 0
        var screenFacts = 0
        var mixedFacts = 0
        var overnightReviewOn = true

        init(libraryReady: Bool = true, recentMeetings: Int = 0, meetingFacts: Int = 0,
             screenFacts: Int = 0, mixedFacts: Int = 0, overnightReviewOn: Bool = true) {
            self.libraryReady = libraryReady
            self.recentMeetings = recentMeetings
            self.meetingFacts = meetingFacts
            self.screenFacts = screenFacts
            self.mixedFacts = mixedFacts
            self.overnightReviewOn = overnightReviewOn
        }

        init(meetings: [Meeting], memory: DreamMemory?, libraryReady: Bool,
             overnightReviewOn: Bool, now: Date = Date()) {
            self.init(libraryReady: libraryReady, overnightReviewOn: overnightReviewOn)
            recentMeetings = meetings.filter {
                CotypingMemoryContextProvider.isEligible($0, now: now)
            }.count
            for item in memory.map(CotypingMemoryContextProvider.memoryItems) ?? [] {
                let age = now.timeIntervalSince(item.updatedAt)
                guard age >= -60, age <= CotypingMemoryContext.maxAge else { continue }
                if item.requiresMeetings && item.requiresScreenMemory {
                    mixedFacts += 1
                } else if item.requiresMeetings {
                    meetingFacts += 1
                } else if item.requiresScreenMemory {
                    screenFacts += 1
                }
            }
        }
    }

    enum State: Equatable, Sendable {
        case off
        case available(String)
        case unavailable(String)
        case nothingSaved(String)

        var message: String? {
            switch self {
            case .off: nil
            case .available(let message), .unavailable(let message), .nothingSaved(let message): message
            }
        }
    }

    var visibleText: State
    var windowText: State
    var meetingMemory: State
    var screenMemory: State

    init(settings: AppSettings, accessibilityGranted: Bool, screenRecordingGranted: Bool = false,
         inventory: Inventory) {
        visibleText = Self.visibleTextState(settings: settings, accessibilityGranted: accessibilityGranted)
        windowText = Self.windowTextState(
            settings: settings, accessibilityGranted: accessibilityGranted,
            screenRecordingGranted: screenRecordingGranted)
        meetingMemory = Self.meetingMemoryState(settings: settings, inventory: inventory)
        screenMemory = Self.screenMemoryState(settings: settings, inventory: inventory)
    }

    private static func visibleTextState(settings: AppSettings, accessibilityGranted: Bool) -> State {
        guard settings.cotypingUseVisibleContext else { return .off }
        guard settings.cotypingEnabled else {
            return .unavailable("Unavailable: autocomplete is off.")
        }
        guard accessibilityGranted else {
            return .unavailable("Unavailable: Accessibility permission is needed to read nearby text.")
        }
        return .available("Available in apps that expose their text to Accessibility.")
    }

    private static func windowTextState(settings: AppSettings, accessibilityGranted: Bool,
                                        screenRecordingGranted: Bool) -> State {
        guard settings.cotypingUseWindowText else { return .off }
        guard settings.cotypingEnabled else {
            return .unavailable("Unavailable: autocomplete is off.")
        }
        guard accessibilityGranted else {
            return .unavailable("Unavailable: Accessibility permission is needed to find the focused window.")
        }
        guard screenRecordingGranted else {
            return .unavailable("Unavailable: Screen Recording permission is needed to read the window.")
        }
        return .available("Available in every app except excluded apps, sites and private windows.")
    }

    private static func meetingMemoryState(settings: AppSettings, inventory: Inventory) -> State {
        guard settings.cotypingUseMeetingMemory else { return .off }
        guard inventory.libraryReady else {
            return .unavailable("Unavailable: the library is still loading.")
        }
        guard inventory.recentMeetings > 0 || inventory.meetingFacts > 0 else {
            return .nothingSaved("Nothing to use yet: no meetings or meeting-derived work memory in the last 90 days.")
        }
        var parts: [String] = []
        if inventory.recentMeetings > 0 { parts.append(counted(inventory.recentMeetings, "meeting")) }
        if inventory.meetingFacts > 0 { parts.append(counted(inventory.meetingFacts, "saved fact")) }
        return .available("Available: \(parts.joined(separator: " and ")) from the last 90 days.")
    }

    private static func screenMemoryState(settings: AppSettings, inventory: Inventory) -> State {
        guard settings.cotypingUseScreenMemory else { return .off }
        guard inventory.libraryReady else {
            return .unavailable("Unavailable: the library is still loading.")
        }
        let blocked = settings.cotypingUseMeetingMemory ? 0 : inventory.mixedFacts
        let usable = inventory.screenFacts + inventory.mixedFacts - blocked
        if usable > 0 {
            let more = blocked > 0
                ? " \(blocked) more also draw on meetings and need Use meeting and work memory."
                : ""
            return .available("Available: \(counted(usable, "saved fact")) from the last 90 days.\(more)")
        }
        if blocked > 0 {
            let subject = blocked == 1 ? "the 1 saved fact also draws" : "the \(blocked) saved facts also draw"
            return .unavailable("Unavailable: \(subject) on meetings. Turn on Use meeting and work memory.")
        }
        return .nothingSaved(inventory.overnightReviewOn
            ? "Nothing to use yet: no screen-derived work memory is saved. Overnight review adds it."
            : "Nothing to use yet: no screen-derived work memory is saved, and Overnight review is off, so none is being added.")
    }

    private static func counted(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }
}

struct CotypingContextUse: Equatable, Sendable {
    var visibleText = false
    var meetingSources: [String] = []
    var screenSources: [String] = []
    var searchedMemory = false

    init(visibleText: Bool = false, selection: CotypingMemoryContext.Selection = .init(),
         searchedMemory: Bool = false) {
        self.visibleText = visibleText
        self.searchedMemory = searchedMemory
        meetingSources = Self.titles(selection.items.filter(\.requiresMeetings))
        screenSources = Self.titles(selection.items.filter(\.requiresScreenMemory))
    }

    private static func titles(_ items: [CotypingMemoryContext.Item]) -> [String] {
        Array(Set(items.map(\.title))).sorted()
    }
}

struct CotypingPreview: Equatable, Sendable {
    var text = ""
    var suppression: CotypingSuppressionReason?
    var use = CotypingContextUse()
}

struct CotypingContextStatus: Equatable, Identifiable, Sendable {
    enum Tone: Equatable, Sendable {
        case used
        case ready
        case attention
        case off
    }

    var id: String
    var title: String
    var detail: String
    var tone: Tone

    static func rehearsal(availability: CotypingContextAvailability,
                          use: CotypingContextUse?) -> [CotypingContextStatus] {
        [
            visibleText(availability.visibleText, use: use),
            memory(id: "meetings", title: "Meeting and work memory",
                   state: availability.meetingMemory, sources: use?.meetingSources, use: use),
            memory(id: "screen", title: "Screen-derived work memory",
                   state: availability.screenMemory, sources: use?.screenSources, use: use),
        ]
    }

    private static func visibleText(_ state: CotypingContextAvailability.State,
                                    use: CotypingContextUse?) -> CotypingContextStatus {
        let title = "Visible text above the field"
        switch state {
        case .off:
            return .init(id: "visible", title: title, detail: "Off", tone: .off)
        case .available, .nothingSaved:
            return use?.visibleText == true
                ? .init(id: "visible", title: title, detail: "Used the sample conversation above.", tone: .used)
                : .init(id: "visible", title: title, detail: "On. The sample conversation above stands in for nearby text.",
                        tone: .ready)
        case .unavailable(let reason):
            let here = use?.visibleText == true ? "Used the sample conversation above. " : ""
            return .init(id: "visible", title: title, detail: "\(here)In other apps: \(reason)", tone: .attention)
        }
    }

    private static func memory(id: String, title: String, state: CotypingContextAvailability.State,
                               sources: [String]?, use: CotypingContextUse?) -> CotypingContextStatus {
        switch state {
        case .off:
            return .init(id: id, title: title, detail: "Off", tone: .off)
        case .unavailable(let reason), .nothingSaved(let reason):
            return .init(id: id, title: title, detail: reason, tone: .attention)
        case .available(let detail):
            if let sources, !sources.isEmpty {
                return .init(id: id, title: title, detail: "Used: \(sources.joined(separator: ", "))", tone: .used)
            }
            if use?.searchedMemory == true {
                return .init(id: id, title: title, detail: "No relevant memory found.", tone: .ready)
            }
            return .init(id: id, title: title, detail: detail, tone: .ready)
        }
    }
}

enum CotypingRehearsalConversation {
    struct Message: Equatable, Identifiable, Sendable {
        var sender: String
        var text: String
        var id: String { text }
        var line: String { "\(sender): \(text)" }
    }

    static let sample: [Message] = [
        .init(sender: "Sarah", text: "The migration timeline we scoped yesterday still works for my team."),
        .init(sender: "Sarah", text: "Daniel can start the database cutover on Thursday if you confirm today."),
    ]

    static func snapshot(of messages: [Message] = sample) -> CotypingVisibleContext.Snapshot? {
        let window = CGRect(x: 0, y: 0, width: 800, height: 720)
        let field = CGRect(x: 40, y: 560, width: 720, height: 120)
        let target = CotypingVisibleContext.Target(
            appName: "LokalBot", bundleID: nil, windowID: "rehearsal", focusID: "reply",
            scopeID: "conversation", windowTitle: "Settings", sourceURL: nil, hasWebContent: false,
            focusedSecureField: false, windowFrame: window, fieldFrame: field, scopeFrame: window)
        var nodes: [CotypingVisibleContextReplay.Node] = []
        var bottom = field.minY - 12
        for (index, message) in messages.enumerated().reversed() {
            let frame = CGRect(x: field.minX, y: bottom - 48, width: field.width, height: 48)
            guard frame.minY >= window.minY else { break }
            nodes.append(.init(
                region: .init(id: "message-\(index)", role: "AXStaticText", frame: frame,
                              hidden: false, secure: false),
                children: [], text: message.line))
            bottom = frame.minY - 8
        }
        let root = CotypingVisibleContextReplay.Node(
            region: .init(id: "conversation", role: "AXGroup", frame: window, hidden: false, secure: false),
            children: nodes.map(\.region.id))
        return CotypingVisibleContextReplay(.init(target: target, nodes: [root] + nodes)).capture(enabled: true)
    }
}

extension AppState {
    func cotypingContextAvailability(accessibilityGranted: Bool,
                                     screenRecordingGranted: Bool = false) -> CotypingContextAvailability {
        CotypingContextAvailability(
            settings: settings,
            accessibilityGranted: accessibilityGranted,
            screenRecordingGranted: screenRecordingGranted,
            inventory: .init(meetings: meetings, memory: dreamMemory, libraryReady: libraryReady,
                             overnightReviewOn: settings.dreamingEnabled))
    }
}
