import Combine
import Foundation

@MainActor
final class AgentReadAccess: ObservableObject {
    enum Kind: String, CaseIterable, Codable, Identifiable, Sendable {
        case meetings, screenMemory, personalContext, files, agentNotes

        var id: String { rawValue }
    }

    struct Choices: Codable, Equatable, Sendable {
        var kinds: Set<Kind> = [.meetings]
        var screenScope: ScreenMemoryAccessProfile.Scope = .recentWeek
    }

    static let choicesFileName = "agent-read-choices.json"

    let meetings: AgentAccessManager
    let screenMemory: ScreenMemoryAccessManager
    let personalContext: PersonalContextAccessManager
    let files: FilesAccessManager
    let agentNotes: AgentNotesAccessManager
    private let choicesURL: URL
    private var remembered: Choices
    private var forwarding: Set<AnyCancellable> = []

    init(meetings: AgentAccessManager, screenMemory: ScreenMemoryAccessManager,
         personalContext: PersonalContextAccessManager, files: FilesAccessManager,
         agentNotes: AgentNotesAccessManager? = nil, root: URL) {
        self.meetings = meetings
        self.screenMemory = screenMemory
        self.personalContext = personalContext
        self.files = files
        let agentNotes = agentNotes ?? AgentNotesAccessManager(gate: AgentNotesAccessGate(root: root))
        self.agentNotes = agentNotes
        choicesURL = root.appendingPathComponent("control", isDirectory: true)
            .appendingPathComponent(Self.choicesFileName)
        remembered = Self.load(from: choicesURL)
        let changes: [ObservableObjectPublisher] = [
            meetings.objectWillChange, screenMemory.objectWillChange,
            personalContext.objectWillChange, files.objectWillChange, agentNotes.objectWillChange,
        ]
        for change in changes {
            change.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &forwarding)
        }
    }

    var isEnabled: Bool { !granted.isEmpty }

    var granted: Set<Kind> { Set(Kind.allCases.filter(isGranted)) }

    func isGranted(_ kind: Kind) -> Bool {
        switch kind {
        case .meetings: meetings.isEnabled
        case .screenMemory: screenMemory.isEnabled
        case .personalContext: personalContext.isEnabled
        case .files: files.isEnabled
        case .agentNotes: agentNotes.isEnabled
        }
    }

    func isTicked(_ kind: Kind) -> Bool {
        isEnabled ? isGranted(kind) : remembered.kinds.contains(kind)
    }

    func canUntick(_ kind: Kind) -> Bool {
        !isEnabled || granted != [kind]
    }

    var screenScope: ScreenMemoryAccessProfile.Scope {
        screenMemory.isEnabled ? screenMemory.profile.scope : remembered.screenScope
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        if enabled {
            let kinds = remembered.kinds.isEmpty ? Choices().kinds : remembered.kinds
            screenMemory.setScope(remembered.screenScope)
            for kind in Kind.allCases where kinds.contains(kind) { grant(kind, true) }
        } else {
            remember(Choices(kinds: granted, screenScope: screenScope))
            for kind in Kind.allCases { grant(kind, false) }
        }
        objectWillChange.send()
    }

    func setTicked(_ kind: Kind, _ ticked: Bool) {
        guard isEnabled else {
            var choices = remembered
            if ticked { choices.kinds.insert(kind) } else { choices.kinds.remove(kind) }
            remember(choices)
            objectWillChange.send()
            return
        }
        guard ticked || canUntick(kind) else { return }
        grant(kind, ticked)
    }

    func setGranted(_ kind: Kind, _ on: Bool) {
        if on {
            guard !isGranted(kind) else { return }
            if kind == .screenMemory { screenMemory.setScope(remembered.screenScope) }
            grant(kind, true)
        } else if granted == [kind] {
            setEnabled(false)
            return
        } else {
            grant(kind, false)
        }
        objectWillChange.send()
    }

    func setScreenScope(_ scope: ScreenMemoryAccessProfile.Scope) {
        if screenMemory.isEnabled {
            screenMemory.setScope(scope)
        } else {
            var choices = remembered
            choices.screenScope = scope
            remember(choices)
            objectWillChange.send()
        }
    }

    private func grant(_ kind: Kind, _ on: Bool) {
        switch kind {
        case .meetings: meetings.setEnabled(on)
        case .screenMemory: screenMemory.setEnabled(on)
        case .personalContext: personalContext.setEnabled(on)
        case .files: files.setEnabled(on)
        case .agentNotes: agentNotes.setEnabled(on)
        }
    }

    private func remember(_ choices: Choices) {
        remembered = choices
        let directory = choicesURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(choices).write(to: choicesURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: choicesURL.path)
        } catch {
            lokalbotLog("agent access: could not save the boxes: \(error.localizedDescription)")
        }
    }

    private static func load(from url: URL) -> Choices {
        guard let data = try? Data(contentsOf: url),
              let choices = try? JSONDecoder().decode(Choices.self, from: data) else { return Choices() }
        return choices
    }
}
