import Foundation

/// Coding-agent work for one local day, ready to join the day's evidence.
struct CodingAgentDayScan: Sendable {
    var interval: DateInterval
    var bursts: [CodingAgentBurst]
    var sessionCount: Int
    var filesRead: Int
    var bytesRead: Int
    var unreadableFiles: [String]
    var excludedSessions: Int

    var evidenceCharacters: Int { bursts.reduce(0) { $0 + $1.evidenceText().count } }
}

/// Collects bursts from every enabled agent for a day and applies the
/// person's project-folder exclusions before anything leaves the reader.
struct CodingAgentSessionScanner: Sendable {
    var readers: [any CodingAgentSessionReader]
    /// Sessions whose working directory is inside one of these folders are
    /// dropped, for repositories whose work must never enter the library.
    var excludedFolders: [String] = []

    static func standard(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        agents: Set<CodingAgentKind> = Set(CodingAgentKind.allCases),
        excludedFolders: [String] = []
    ) -> CodingAgentSessionScanner {
        let readers: [any CodingAgentSessionReader] = CodingAgentKind.allCases
            .filter(agents.contains)
            .map { agent in
                switch agent {
                case .claudeCode:
                    ClaudeCodeSessionReader(
                        root: home.appendingPathComponent(".claude/projects", isDirectory: true))
                case .codex:
                    CodexSessionReader(root: home.appendingPathComponent(".codex", isDirectory: true))
                case .antigravity:
                    AntigravitySessionReader.standard(home: home)
                case .t3Code:
                    T3CodeSessionReader(
                        root: home.appendingPathComponent(".t3/userdata", isDirectory: true))
                }
            }
        return CodingAgentSessionScanner(readers: readers, excludedFolders: excludedFolders)
    }

    func scan(day: Date, calendar: Calendar = .current) -> CodingAgentDayScan {
        scan(from: day, through: day, calendar: calendar)
    }

    /// Every local day from `firstDay` through `lastDay`, reading each
    /// transcript once. Bursts never cross midnight, so each belongs to
    /// exactly one day's evidence.
    func scan(
        from firstDay: Date, through lastDay: Date, calendar: Calendar = .current,
        cache: CodingAgentParseCache? = nil
    ) -> CodingAgentDayScan {
        let start = calendar.startOfDay(for: min(firstDay, lastDay))
        let lastStart = calendar.startOfDay(for: max(firstDay, lastDay))
        let end = calendar.date(byAdding: .day, value: 1, to: lastStart) ?? lastStart.addingTimeInterval(86_400)
        let interval = DateInterval(start: start, end: end)
        var scan = CodingAgentDayScan(
            interval: interval, bursts: [], sessionCount: 0, filesRead: 0, bytesRead: 0,
            unreadableFiles: [], excludedSessions: 0)
        let results = readers.map { $0.transcripts(in: interval, cache: cache) }
        var claimed: Set<CodingAgentSessionKey> = []
        for result in results {
            scan.filesRead += result.filesRead
            scan.bytesRead += result.bytesRead
            scan.unreadableFiles += result.unreadableFiles
            claimed.formUnion(result.claimedSessions)
        }
        for result in results {
            for transcript in result.transcripts {
                if claimed.contains(CodingAgentSessionKey(agent: transcript.agent, sessionID: transcript.sessionID)) {
                    continue
                }
                guard !isExcluded(transcript.workingDirectory) else {
                    scan.excludedSessions += 1
                    continue
                }
                let days = Dictionary(grouping: transcript.events) { calendar.startOfDay(for: $0.at) }
                let bursts = days.keys.sorted().flatMap { day -> [CodingAgentBurst] in
                    var daily = transcript
                    daily.events = days[day] ?? []
                    return CodingAgentBurstBuilder.bursts(from: daily)
                }
                guard !bursts.isEmpty else { continue }
                scan.sessionCount += 1
                scan.bursts += bursts
            }
        }
        scan.bursts.sort { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            return lhs.id < rhs.id
        }
        return scan
    }

    func isExcluded(_ workingDirectory: String?) -> Bool {
        guard let workingDirectory else { return false }
        let path = (workingDirectory as NSString).standardizingPath
        return excludedFolders.contains { rule in
            let folder = ((rule.trimmingCharacters(in: .whitespacesAndNewlines) as NSString)
                .expandingTildeInPath as NSString).standardizingPath
            guard !folder.isEmpty, folder != "/" else { return false }
            return path == folder || path.hasPrefix(folder + "/")
        }
    }
}
