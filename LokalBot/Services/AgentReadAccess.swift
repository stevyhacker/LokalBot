import Combine
import Foundation

/// Settings → Privacy → External agents: one switch for reading LokalBot data,
/// with a box for each kind under it. Each kind keeps its own marker in
/// `control/`, which is what `lokalbot-cli` and its MCP server check, with the
/// app closed too. The switch only writes and removes those markers: turning
/// it on grants the ticked kinds; turning it off removes them all and
/// remembers the boxes and the screen history range for next time.
///
/// The switch is on exactly while some kind is granted, so grants made before
/// it existed (a toggle per kind), or by an agent setup request, show as they
/// are and nothing widens on upgrade. Changing LokalBot's settings stays a
/// separate grant.
@MainActor
final class AgentReadAccess: ObservableObject {
    enum Kind: String, CaseIterable, Codable, Identifiable, Sendable {
        case meetings, screenMemory, personalContext, files

        var id: String { rawValue }
    }

    /// The boxes and history range while the switch is off.
    struct Choices: Codable, Equatable, Sendable {
        var kinds: Set<Kind> = [.meetings]
        var screenScope: ScreenMemoryAccessProfile.Scope = .recentWeek
    }

    static let choicesFileName = "agent-read-choices.json"

    let meetings: AgentAccessManager
    let screenMemory: ScreenMemoryAccessManager
    let personalContext: PersonalContextAccessManager
    let files: FilesAccessManager
    private let choicesURL: URL
    private var remembered: Choices
    private var forwarding: Set<AnyCancellable> = []

    init(meetings: AgentAccessManager, screenMemory: ScreenMemoryAccessManager,
         personalContext: PersonalContextAccessManager, files: FilesAccessManager, root: URL) {
        self.meetings = meetings
        self.screenMemory = screenMemory
        self.personalContext = personalContext
        self.files = files
        choicesURL = root.appendingPathComponent("control", isDirectory: true)
            .appendingPathComponent(Self.choicesFileName)
        remembered = Self.load(from: choicesURL)
        // Agent setup and the per-kind managers change grants directly; the
        // switch and boxes follow them.
        let changes: [ObservableObjectPublisher] = [
            meetings.objectWillChange, screenMemory.objectWillChange,
            personalContext.objectWillChange, files.objectWillChange,
        ]
        for change in changes {
            change.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &forwarding)
        }
    }

    /// Some kind is granted.
    var isEnabled: Bool { !granted.isEmpty }

    var granted: Set<Kind> { Set(Kind.allCases.filter(isGranted)) }

    func isGranted(_ kind: Kind) -> Bool {
        switch kind {
        case .meetings: meetings.isEnabled
        case .screenMemory: screenMemory.isEnabled
        case .personalContext: personalContext.isEnabled
        case .files: files.isEnabled
        }
    }

    /// What the box shows: granted while the switch is on, remembered while it is off.
    func isTicked(_ kind: Kind) -> Bool {
        isEnabled ? isGranted(kind) : remembered.kinds.contains(kind)
    }

    /// The last ticked box can't be unticked; the switch turns everything off.
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
