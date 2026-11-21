import Foundation

typealias AgentLocalize = (String) -> String

struct AgentFileTarget: Equatable {
    enum Place: Equatable { case workingFolder, outside }

    let url: URL
    let name: String
    let folder: String
    let place: Place

    static func resolve(_ path: String, workspace: URL, workspaceName: String) -> AgentFileTarget {
        var text = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("@") { text.removeFirst() }
        text = (text as NSString).expandingTildeInPath
        let raw = text.hasPrefix("/") ? URL(fileURLWithPath: text) : workspace.appendingPathComponent(text)
        let url = AgentApprovalPolicy.canonicalFileURL(raw) ?? raw.standardizedFileURL
        let root = AgentApprovalPolicy.canonicalFileURL(workspace) ?? workspace.standardizedFileURL
        let rootParts = root.pathComponents
        let parent = url.deletingLastPathComponent().pathComponents
        guard parent.starts(with: rootParts) else {
            let folder = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
            return .init(url: url, name: url.lastPathComponent, folder: folder, place: .outside)
        }
        let inner = parent.dropFirst(rootParts.count)
        return .init(url: url, name: url.lastPathComponent,
                     folder: ([workspaceName] + inner).joined(separator: "/"), place: .workingFolder)
    }
}

struct AgentChangedFile: Identifiable, Equatable {
    enum Change: Equatable {
        case created
        case replaced
        case edited
        case written
    }

    var id: String { target.url.path }
    let target: AgentFileTarget
    var change: Change
    var lineCount: Int?
    var stepID: String

    static func list(in items: [AgentTranscriptItem], workspace: URL, workspaceName: String,
                     existedBefore: [String: Bool]) -> [AgentChangedFile] {
        var files: [AgentChangedFile] = []
        for item in items {
            guard case .tool(let id, let name, let args, _, .succeeded) = item,
                  ["write", "edit"].contains(name.lowercased()),
                  let path = AgentStepWording.arguments(args).path else { continue }
            let target = AgentFileTarget.resolve(path, workspace: workspace, workspaceName: workspaceName)
            let isWrite = name.lowercased() == "write"
            let lines = isWrite ? AgentStepWording.arguments(args).content.map(lineCount) : nil
            let change: Change = isWrite
                ? existedBefore[id].map { $0 ? .replaced : .created } ?? .written
                : .edited
            if let index = files.firstIndex(where: { $0.id == target.url.path }) {
                if files[index].change != .created { files[index].change = change }
                if let lines { files[index].lineCount = lines }
                files[index].stepID = id
            } else {
                files.append(.init(target: target, change: change, lineCount: lines, stepID: id))
            }
        }
        return files
    }

    static func lineCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let body = text.hasSuffix("\n") ? String(text.dropLast()) : text
        return body.components(separatedBy: "\n").count
    }

    func changeLabel(localize: AgentLocalize) -> String? {
        switch change {
        case .created: localize("New file")
        case .replaced: localize("Replaced")
        case .edited: localize("Edited")
        case .written: nil
        }
    }

    func detail(localize: AgentLocalize) -> String {
        var parts = [changeLabel(localize: localize)].compactMap { $0 }
        if let lineCount {
            parts.append(lineCount == 1 ? localize("1 line") : String(format: localize("%lld lines"), lineCount))
        }
        parts.append(target.folder)
        return parts.joined(separator: " · ")
    }
}

struct AgentStepLabel: Equatable {
    let done: String
    let doing: String
    let detail: String?
    let beginsWithName: Bool

    func text(_ status: AgentToolStatus, taskIsWorking: Bool, localize: AgentLocalize) -> String {
        switch status {
        case .succeeded: done
        case .failed: String(format: localize("%@ · failed"), doing)
        case .running: taskIsWorking ? doing + "…" : String(format: localize("%@ · not finished"), doing)
        }
    }
}

enum AgentStepWording {
    struct Context {
        var workspace: URL
        var workspaceName: String
        var meetingTitle: (String) -> String? = { _ in nil }
    }

    struct Arguments {
        var path: String?
        var command: String?
        var content: String?
    }

    static func arguments(_ argsJSON: String) -> Arguments {
        let object = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any] ?? [:]
        return .init(path: object["path"] as? String ?? object["file_path"] as? String,
                     command: object["command"] as? String,
                     content: object["content"] as? String)
    }

    static func label(for item: AgentTranscriptItem, context: Context, localize: AgentLocalize) -> AgentStepLabel? {
        guard case .tool(_, let name, let args, _, _) = item else { return nil }
        return label(tool: name, argsJSON: args, context: context, localize: localize)
    }

    static func label(tool: String, argsJSON: String, context: Context, localize: AgentLocalize) -> AgentStepLabel {
        let arguments = arguments(argsJSON)
        let name = tool.lowercased()
        if let verbs = fileVerbs[name], let path = arguments.path {
            let target = AgentFileTarget.resolve(path, workspace: context.workspace, workspaceName: context.workspaceName)
            return named(verbs.done, verbs.doing, target.name, detail: target.folder, localize: localize)
        }
        if ["bash", "shell"].contains(name) {
            return command(arguments.command ?? "", context: context, localize: localize)
        }
        return named("Used %@", "Using %@", tool, detail: nil, localize: localize)
    }

    private static let fileVerbs: [String: (done: String, doing: String)] = [
        "read": ("Read %@", "Reading %@"),
        "write": ("Wrote %@", "Writing %@"),
        "edit": ("Edited %@", "Editing %@"),
    ]

    private static func command(_ text: String, context: Context, localize: AgentLocalize) -> AgentStepLabel {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let shown = firstLine.count > 120 ? String(firstLine.prefix(119)) + "…" : firstLine
        let other = phrase("Ran a command", "Running a command", detail: shown.isEmpty ? nil : shown, localize: localize)
        guard let words = AgentApprovalPolicy.plainCommandWords(text), words.count >= 2,
              words[0] == "lokalbot-cli" else { return other }
        var subject: String?
        var skipValue = false
        for word in words.dropFirst(2) {
            if skipValue { skipValue = false; continue }
            if word.hasPrefix("-") { skipValue = !word.contains("=") && !flagsWithoutValue.contains(word); continue }
            subject = word
            break
        }
        func option(_ name: String) -> String? {
            if let joined = words.first(where: { $0.hasPrefix(name + "=") }) { return String(joined.dropFirst(name.count + 1)) }
            guard let index = words.firstIndex(of: name), words.indices.contains(index + 1) else { return nil }
            return words[index + 1]
        }
        switch words[1] {
        case "search":
            return phrase("Searched meeting library", "Searching meeting library", detail: subject, localize: localize)
        case "get":
            return phrase("Read meeting notes", "Reading meeting notes",
                              detail: subject.flatMap(context.meetingTitle), localize: localize)
        case "list":
            return phrase("Listed meetings", "Listing meetings", detail: option("--query"), localize: localize)
        case "brief":
            return phrase("Read your briefing", "Reading your briefing", detail: nil, localize: localize)
        case "actions":
            return phrase("Read action items", "Reading action items", detail: nil, localize: localize)
        default:
            return other
        }
    }

    private static let flagsWithoutValue: Set<String> = ["--table"]

    private static func phrase(_ done: String, _ doing: String, detail: String?,
                               localize: AgentLocalize) -> AgentStepLabel {
        .init(done: localize(done), doing: localize(doing), detail: detail, beginsWithName: false)
    }

    private static func named(_ done: String, _ doing: String, _ name: String, detail: String?,
                              localize: AgentLocalize) -> AgentStepLabel {
        let format = localize(done)
        return .init(done: String(format: format, name), doing: String(format: localize(doing), name),
                     detail: detail, beginsWithName: format.hasPrefix("%"))
    }

    static func summary(_ labels: [(text: String, beginsWithName: Bool)], lowercaseFollowing: Bool) -> String {
        var seen = Set<String>()
        var parts: [String] = []
        for label in labels where seen.insert(label.text).inserted {
            if parts.isEmpty || !lowercaseFollowing || label.beginsWithName {
                parts.append(label.text)
            } else {
                parts.append(label.text.prefix(1).lowercased() + label.text.dropFirst())
            }
        }
        return parts.joined(separator: ", ")
    }

    static func count(_ steps: Int, localize: AgentLocalize) -> String {
        steps == 1 ? localize("1 step") : String(format: localize("%lld steps"), steps)
    }
}

struct AgentStepGroup: Identifiable, Equatable {
    let id: String
    let entries: [AgentTranscriptItem]
    let isTurnSummary: Bool

    var steps: [AgentTranscriptItem] {
        entries.filter { if case .tool = $0 { true } else { false } }
    }
    var hasFailure: Bool {
        entries.contains { if case .tool(_, _, _, _, .failed) = $0 { true } else { false } }
    }
}

enum AgentTranscriptBlock: Identifiable, Equatable {
    case user(AgentTranscriptItem)
    case said(AgentTranscriptItem)
    case answer(AgentTranscriptItem, steps: [AgentTranscriptItem])
    case notice(AgentTranscriptItem)
    case steps(AgentStepGroup)
    case live(AgentTranscriptItem)

    var id: String {
        switch self {
        case .user(let item), .said(let item), .answer(let item, _), .notice(let item), .live(let item): item.id
        case .steps(let group): "steps." + group.id
        }
    }

    var searchableText: String {
        switch self {
        case .user(let item), .said(let item), .answer(let item, _), .notice(let item), .live(let item):
            item.searchableText
        case .steps(let group): group.entries.map(\.searchableText).joined(separator: "\n")
        }
    }
}

enum AgentTranscriptLayout {
    static func make(_ items: [AgentTranscriptItem], isWorking: Bool) -> [AgentTranscriptBlock] {
        var turns: [[AgentTranscriptItem]] = []
        for item in items {
            if case .approval = item { continue }
            if case .user = item { turns.append([item]) } else if turns.isEmpty { turns.append([item]) } else {
                turns[turns.count - 1].append(item)
            }
        }
        return turns.enumerated().flatMap { index, turn in
            layout(turn, finished: !(isWorking && index == turns.count - 1))
        }
    }

    private static func isStep(_ item: AgentTranscriptItem) -> Bool {
        if case .tool = item { true } else { false }
    }

    private static func layout(_ turn: [AgentTranscriptItem], finished: Bool) -> [AgentTranscriptBlock] {
        var blocks: [AgentTranscriptBlock] = []
        var body = turn[...]
        if case .user = body.first { blocks.append(.user(body.removeFirst())) }
        let lastSaid = body.lastIndex { if case .assistant = $0 { true } else { false } }
        if finished, let lastSaid, !body[body.index(after: lastSaid)...].contains(where: isStep) {
            var pending: [AgentTranscriptItem] = []
            func fold() {
                if pending.contains(where: isStep) {
                    blocks.append(.steps(.init(id: pending[0].id, entries: pending, isTurnSummary: true)))
                } else {
                    blocks += pending.map { .said($0) }
                }
                pending = []
            }
            for item in body[..<lastSaid] {
                if case .notice = item { fold(); blocks.append(.notice(item)) } else { pending.append(item) }
            }
            fold()
            blocks.append(.answer(body[lastSaid], steps: body.filter(isStep)))
            blocks += body[body.index(after: lastSaid)...].map { .notice($0) }
            return blocks
        }
        var run: [AgentTranscriptItem] = []
        func fold() {
            var live: AgentTranscriptItem?
            if !finished, case .tool(_, _, _, _, .running)? = run.last { live = run.removeLast() }
            if let first = run.first { blocks.append(.steps(.init(id: first.id, entries: run, isTurnSummary: false))) }
            if let live { blocks.append(.live(live)) }
            run = []
        }
        for item in body {
            switch item {
            case .tool: run.append(item)
            case .assistant: fold(); blocks.append(.said(item))
            case .notice: fold(); blocks.append(.notice(item))
            case .user, .approval: break
            }
        }
        fold()
        return blocks
    }
}

enum AgentTaskStatus: Equatable {
    case notStarted
    case saved
    case starting
    case working
    case needsApproval(Int)
    case needsAttention
    case stopped
    case done(changedFiles: Int)

    enum Tone: Equatable { case quiet, working, attention, done }

    static func resolve(state: AgentSessionController.SessionState, pendingApprovals: Int, hasTurnError: Bool,
                        wasStopped: Bool, items: [AgentTranscriptItem], hasSavedConversation: Bool,
                        changedFiles: Int) -> AgentTaskStatus {
        if pendingApprovals > 0 { return .needsApproval(pendingApprovals) }
        if hasTurnError { return .needsAttention }
        switch state {
        case .failed: return .needsAttention
        case .starting: return .starting
        case .running: return .working
        case .idle, .ready:
            if items.isEmpty { return hasSavedConversation ? .saved : .notStarted }
            if wasStopped { return .stopped }
            let last = items.last { if case .notice = $0 { false } else { true } }
            if state == .ready, case .assistant(_, _, false)? = last { return .done(changedFiles: changedFiles) }
            return .saved
        }
    }

    var tone: Tone {
        switch self {
        case .notStarted, .saved, .stopped: .quiet
        case .starting, .working: .working
        case .needsApproval, .needsAttention: .attention
        case .done: .done
        }
    }

    var symbol: String {
        switch self {
        case .notStarted, .saved, .stopped: "bubble.left"
        case .starting, .working: "circle.dotted"
        case .needsApproval: "hand.raised.fill"
        case .needsAttention: "exclamationmark.circle"
        case .done: "checkmark.circle"
        }
    }

    func title(localize: AgentLocalize) -> String? {
        switch self {
        case .notStarted: localize("Not started")
        case .saved: nil
        case .starting: localize("Starting…")
        case .working: localize("Working…")
        case .needsApproval: localize("Needs approval")
        case .needsAttention: localize("Needs attention")
        case .stopped: localize("Stopped")
        case .done: localize("Done")
        }
    }

    func line(localize: AgentLocalize) -> String? {
        guard case .done(let changed) = self, changed > 0 else { return title(localize: localize) }
        return changed == 1 ? localize("Done · 1 file changed")
            : String(format: localize("Done · %lld files changed"), changed)
    }
}

struct AgentTaskListSection: Identifiable, Equatable {
    enum Kind: Equatable {
        case pinned, today, yesterday
        case day(Date)
        case earlier
    }

    struct Entry: Equatable {
        let id: UUID
        let modifiedAt: Date
        let isPinned: Bool
    }

    let kind: Kind
    let ids: [UUID]

    var id: String {
        switch kind {
        case .pinned: "pinned"
        case .today: "today"
        case .yesterday: "yesterday"
        case .day(let date): "day.\(Int(date.timeIntervalSinceReferenceDate))"
        case .earlier: "earlier"
        }
    }

    static func make(_ entries: [Entry], now: Date, calendar: Calendar) -> [AgentTaskListSection] {
        var order: [Kind] = []
        var groups: [[UUID]] = []
        func add(_ id: UUID, to kind: Kind) {
            if let index = order.firstIndex(of: kind) { groups[index].append(id) } else {
                order.append(kind); groups.append([id])
            }
        }
        let today = calendar.startOfDay(for: now)
        for entry in entries where entry.isPinned { add(entry.id, to: .pinned) }
        for entry in entries.filter({ !$0.isPinned }).sorted(by: { $0.modifiedAt > $1.modifiedAt }) {
            let day = calendar.startOfDay(for: entry.modifiedAt)
            let age = calendar.dateComponents([.day], from: day, to: today).day ?? 0
            if entry.modifiedAt == .distantPast { add(entry.id, to: .earlier) } else if age <= 0 {
                add(entry.id, to: .today)
            } else if age == 1 { add(entry.id, to: .yesterday) } else { add(entry.id, to: .day(day)) }
        }
        return zip(order, groups).map { .init(kind: $0, ids: $1) }
    }

    func title(locale: Locale, localize: AgentLocalize) -> String {
        switch kind {
        case .pinned: localize("Pinned")
        case .today: localize("Today")
        case .yesterday: localize("Yesterday")
        case .day(let date):
            date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale))
        case .earlier: localize("Earlier")
        }
    }
}

extension AgentApprovalMode {
    var chipTitle: String {
        switch self {
        case .askBeforeChanges: "Asks first"
        case .approveReads: "Reads any file"
        case .approveReadsAndEdits: "Edits any file"
        case .fullAccess: "Full access"
        }
    }

    var levelTitle: String {
        switch self {
        case .askBeforeChanges: "Ask first"
        case .approveReads: "Read any file"
        case .approveReadsAndEdits: "Edit any file"
        case .fullAccess: "Full access"
        }
    }

    var systemImage: String {
        switch self {
        case .askBeforeChanges: "hand.raised"
        case .approveReads: "eye"
        case .approveReadsAndEdits: "pencil"
        case .fullAccess: "lock.open"
        }
    }

    var needsCaution: Bool { self == .fullAccess }

    func levelDetail(workspaceName: String, localize: AgentLocalize) -> String {
        switch self {
        case .askBeforeChanges:
            String(format: localize("Reads files in %@ without asking, and looks things up in your LokalBot library when the model runs on this Mac. Asks before anything else."), workspaceName)
        case .approveReads:
            localize("Reads any file without asking. Asks before changing files or running commands.")
        case .approveReadsAndEdits:
            localize("Reads and edits files without asking. Asks before running commands.")
        case .fullAccess:
            localize("Runs commands and every other tool without asking. Commands can delete files, change LokalBot’s data or use the network.")
        }
    }

    func capability(localize: AgentLocalize) -> String {
        switch self {
        case .askBeforeChanges:
            localize("It can read your meetings, work in a folder you choose, and asks before changing anything.")
        case .approveReads:
            localize("It can read your meetings and any file on this Mac, and asks before changing anything.")
        case .approveReadsAndEdits:
            localize("It can read and edit any file on this Mac, and asks before running commands.")
        case .fullAccess:
            localize("It can read and edit any file and run commands on this Mac without asking.")
        }
    }
}

struct AgentApprovalPresentation: Equatable {
    enum Place: Equatable {
        case workingFolder
        case outside
        case lokalbotData
        case none
    }

    static let collapsedPreviewLines = 4

    let symbol: String
    let title: String
    let effect: String
    let caution: String?
    let destination: String?
    let preview: String
    let taskAnswer: String?

    var previewLines: [String] { preview.components(separatedBy: "\n") }

    init(request: AgentApprovalRequest, place: Place, targetExists: Bool, workspaceName: String,
         remoteHost: String?, canAllowForTask: Bool, localize: AgentLocalize) {
        let tool = request.tool.lowercased()
        let name = request.path.map { URL(fileURLWithPath: $0).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }
        func named(_ format: String) -> String {
            String(format: localize(name == nil ? "Use %@?" : format), name ?? request.tool)
        }
        func located(_ inside: String) -> String {
            switch place {
            case .lokalbotData: localize("This file is part of LokalBot’s own data.")
            case .outside: String(format: localize("This file is outside %@."), workspaceName)
            case .workingFolder, .none: String(format: localize(inside), workspaceName)
            }
        }
        var sendsResult = false
        switch tool {
        case "write":
            symbol = "hand.raised.fill"
            title = named(targetExists ? "Replace %@?" : "Create %@?")
            effect = located(targetExists ? "Replaces the file in %@." : "Adds a new file to %@.")
            preview = request.content ?? request.summary ?? ""
        case "edit":
            symbol = "hand.raised.fill"
            title = named("Edit %@?")
            effect = located("Changes the file in %@.")
            preview = request.edits.map { edit in
                (edit.oldText.components(separatedBy: "\n").map { "- " + $0 }
                    + edit.newText.components(separatedBy: "\n").map { "+ " + $0 }).joined(separator: "\n")
            }.joined(separator: "\n\n")
        case "read":
            symbol = "hand.raised.fill"
            title = named("Read %@?")
            effect = located("Reads the file in %@.")
            preview = ""
            sendsResult = true
        case "bash", "shell":
            symbol = "terminal"
            title = localize("Run a command?")
            effect = String(format: localize("Runs in %@ with your Mac account’s access, so it can change files or use the network."), workspaceName)
            preview = request.command ?? request.summary ?? ""
            sendsResult = true
        default:
            symbol = "hand.raised.fill"
            title = String(format: localize("Use %@?"), request.tool)
            effect = localize("Runs this tool with the details below.")
            preview = request.arguments ?? request.summary ?? ""
            sendsResult = true
        }
        caution = place == .outside || place == .lokalbotData ? request.path : nil
        destination = sendsResult ? remoteHost.map { String(format: localize("The result goes to the model at %@."), $0) } : nil
        if canAllowForTask {
            taskAnswer = tool == "edit" ? localize("Allow edits for this task") : localize("Allow writes for this task")
        } else {
            taskAnswer = nil
        }
    }

    static func showAll(_ lines: Int, localize: AgentLocalize) -> String {
        String(format: localize("Show all %lld lines"), lines)
    }
}
