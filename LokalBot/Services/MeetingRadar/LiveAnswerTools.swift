import Foundation
import PDFKit

/// A folder the person lets live answers read: documents anywhere in it, and
/// code, commits, pull requests, and issues when it is a git repository.
struct LiveAnswerPlace: Equatable, Sendable {
    var name: String
    var url: URL
    var isRepository: Bool
    /// `owner/repo` when the `origin` remote is on GitHub.
    var gitHub: String?
    /// The checked-out commit, for links that keep pointing at what was read.
    var head: String?

    /// Reads each folder's git details. Missing folders are left out.
    static func load(_ paths: [String]) async -> [LiveAnswerPlace] {
        var places: [LiveAnswerPlace] = []
        var names = Set<String>()
        for path in paths {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            var name = url.lastPathComponent
            while names.contains(name) { name += "-2" }
            names.insert(name)
            let isRepository = FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
            var place = LiveAnswerPlace(name: name, url: url, isRepository: isRepository)
            if isRepository {
                let remote = try? await LiveAnswerTools.git(["remote", "get-url", "origin"], in: url)
                place.gitHub = remote.flatMap { gitHubRepository(fromRemote: $0) }
                place.head = (try? await LiveAnswerTools.git(["rev-parse", "HEAD"], in: url))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            places.append(place)
        }
        return places
    }

    /// `owner/repo` from an https or ssh GitHub remote.
    static func gitHubRepository(fromRemote remote: String) -> String? {
        var text = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://github.com/", "http://github.com/", "git@github.com:", "ssh://git@github.com/"]
        where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
            if text.hasSuffix(".git") { text = String(text.dropLast(4)) }
            let parts = text.split(separator: "/")
            return parts.count == 2 ? "\(parts[0])/\(parts[1])" : nil
        }
        return nil
    }

    func link(path: String, line: Int? = nil) -> String {
        if let gitHub, let head {
            return "https://github.com/\(gitHub)/blob/\(head)/\(path)" + (line.map { "#L\($0)" } ?? "")
        }
        return url.appendingPathComponent(path).absoluteString
    }
}

/// One line of a tool's output that names something on its own (a file
/// line, a commit, a pull request), so a quote found in that line cites it.
struct LiveAnswerLine: Sendable {
    var text: String
    var title: String
    var link: String?
}

/// What a tool returned: the text the model reads, and what the answer may
/// cite from it.
struct LiveAnswerToolOutput: Sendable {
    var text: String
    var kind: RadarAnswer.Source.Kind?
    var title: String = ""
    var link: String?
    var lines: [LiveAnswerLine] = []
    var meetingID: UUID?
    var time: Double?

    static func message(_ text: String) -> LiveAnswerToolOutput {
        LiveAnswerToolOutput(text: text, kind: nil)
    }
}

/// The read-only tools over the person's folders and repositories. Every path
/// stays inside an approved folder; hidden and secret-looking files are never
/// read; in a repository only files git tracks are. Commands run with a short
/// timeout and their output is capped.
enum LiveAnswerTools {
    static let outputCharacters = 4_000
    static let commandTimeout: Duration = .seconds(8)

    // MARK: - Definitions

    static func definitions(places: [LiveAnswerPlace]) -> [[String: Any]] {
        var tools: [[String: Any]] = []
        let repositories = places.filter(\.isRepository).map(\.name)
        let string: [String: Any] = ["type": "string"]
        if !places.isEmpty {
            tools.append(function(
                "search_documents",
                "Find documents, sheets, PDFs and notes in the person's folders whose text or name matches. Returns paths to read.",
                ["query": string.merging(["description": "A few distinctive words."]) { $1 }], required: ["query"]))
            tools.append(function(
                "read_document",
                "Read the parts of one document that match a query: PDF, Word, RTF, sheets (.xlsx, .csv), Markdown, or text.",
                ["path": string.merging(["description": "A path from search_documents, or relative to a folder."]) { $1 },
                 "query": string.merging(["description": "Words to find in it. Empty reads the start."]) { $1 }],
                required: ["path", "query"]))
        }
        if !repositories.isEmpty {
            let repository = string.merging(["enum": repositories]) { $1 }
            tools.append(function(
                "search_code",
                "Search the tracked files of a repository for a literal string, ignoring case. Returns path:line: text.",
                ["repository": repository, "query": string], required: ["repository", "query"]))
            tools.append(function(
                "read_file",
                "Read lines of a tracked file in a repository, numbered.",
                ["repository": repository, "path": string,
                 "start_line": ["type": "integer"], "end_line": ["type": "integer"]],
                required: ["repository", "path", "start_line", "end_line"]))
            tools.append(function(
                "recent_commits",
                "The latest commits of a repository, optionally only those whose message matches, or that touch a path.",
                ["repository": repository, "query": string, "path": string], required: ["repository", "query", "path"]))
            tools.append(function(
                "github",
                "Pull requests or issues of a repository on GitHub: search them, or view one by number with its state, checks, and description.",
                ["repository": repository,
                 "kind": string.merging(["enum": ["pull_requests", "issues"]]) { $1 },
                 "query": string.merging(["description": "Search words; empty lists the latest."]) { $1 },
                 "number": ["type": "integer", "description": "View this one instead of searching; 0 to search."]],
                required: ["repository", "kind", "query", "number"]))
        }
        return tools
    }

    static func function(_ name: String, _ description: String, _ properties: [String: Any],
                         required: [String]) -> [String: Any] {
        ["type": "function",
         "function": ["name": name, "description": description,
                      "parameters": ["type": "object", "properties": properties, "required": required] as [String: Any]]]
    }

    static let names: Set<String> = ["search_documents", "read_document", "search_code", "read_file", "recent_commits", "github"]

    // MARK: - Running

    static func run(_ name: String, _ arguments: [String: Any], places: [LiveAnswerPlace]) async -> LiveAnswerToolOutput {
        func text(_ key: String) -> String { (arguments[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        func int(_ key: String) -> Int? { (arguments[key] as? Int) ?? (arguments[key] as? String).flatMap(Int.init) }
        let repository = places.first { $0.isRepository && $0.name == text("repository") }
        do {
            switch name {
            case "search_documents":
                return await searchDocuments(text("query"), places: places)
            case "read_document":
                return try await readDocument(text("path"), query: text("query"), places: places)
            case "search_code":
                guard let repository else { return .message("No repository named \(text("repository")).") }
                return try await searchCode(text("query"), in: repository)
            case "read_file":
                guard let repository else { return .message("No repository named \(text("repository")).") }
                return try await readFile(text("path"), from: int("start_line") ?? 1, to: int("end_line") ?? 80, in: repository)
            case "recent_commits":
                guard let repository else { return .message("No repository named \(text("repository")).") }
                return try await recentCommits(query: text("query"), path: text("path"), in: repository)
            case "github":
                guard let repository else { return .message("No repository named \(text("repository")).") }
                let issues = text("kind") == "issues"
                if let number = int("number"), number > 0 {
                    return try await viewOnGitHub(number, issues: issues, in: repository)
                }
                return try await searchGitHub(text("query"), issues: issues, in: repository)
            default:
                return .message("Unknown tool \(name).")
            }
        } catch {
            return .message("That didn't work: \(error.localizedDescription)")
        }
    }

    // MARK: - Documents

    static let readableExtensions: Set<String> = [
        "pdf", "docx", "doc", "rtf", "rtfd", "odt", "html", "htm", "webarchive", "xlsx", "csv", "tsv",
        "md", "markdown", "txt", "text", "json", "yaml", "yml", "xml", "log",
    ]

    static func searchDocuments(_ query: String, places: [LiveAnswerPlace]) async -> LiveAnswerToolOutput {
        guard !query.isEmpty else { return .message("Give a query.") }
        var found: [URL] = []
        for place in places {
            // Spotlight's content index, limited to this folder.
            let output = (try? await run("/usr/bin/mdfind", ["-onlyin", place.url.path, query], in: nil)) ?? ""
            found += output.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
                .filter { isReadable($0, places: places) }
        }
        if found.isEmpty {
            // Spotlight can be off, still indexing, or skip the folder (it
            // doesn't index ~/Library): rank file names by the query's words.
            let words = PersonalContextSelection.contentWords(query)
            var ranked: [(url: URL, score: Int)] = []
            for place in places {
                for url in files(in: place.url, limit: 4_000) where isReadable(url, places: places) {
                    let score = nameScore(url.deletingPathExtension().lastPathComponent, words: words)
                    if score > 0 { ranked.append((url, score)) }
                }
            }
            found = ranked.sorted { $0.score > $1.score }.map(\.url)
        }
        let unique = Array(NSOrderedSet(array: found).compactMap { $0 as? URL }.prefix(10))
        guard !unique.isEmpty else { return .message("No documents match “\(query)”.") }
        let lines = unique.map { url -> String in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let date = values?.contentModificationDate.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? ""
            return "\(displayPath(url, places: places)) · modified \(date)"
        }
        return .message(lines.joined(separator: "\n"))
    }

    /// How many of the query's words a file name holds: the same word, or one
    /// with the same first four letters, so "price" finds "pricing".
    static func nameScore(_ name: String, words: Set<String>) -> Int {
        let nameWords = PersonalContextSelection.contentWords(name)
        var score = 0
        for word in words where nameWords.contains(where: { sameStem($0, word) }) { score += 1 }
        return score
    }

    private static func sameStem(_ first: String, _ second: String) -> Bool {
        guard first != second else { return true }
        guard first.count >= 4, second.count >= 4 else { return false }
        return first.prefix(4) == second.prefix(4)
    }

    static func readDocument(_ path: String, query: String, places: [LiveAnswerPlace]) async throws -> LiveAnswerToolOutput {
        guard let url = resolve(path, places: places), isReadable(url, places: places) else {
            return .message("That file isn't in a folder LokalBot may read, or its type can't be read.")
        }
        let name = url.lastPathComponent
        let full = try await documentText(url)
        let excerpt = excerpt(of: full, query: query)
        guard !excerpt.isEmpty else { return .message("\(name) has no readable text.") }
        return LiveAnswerToolOutput(text: "\(displayPath(url, places: places))\n\(excerpt)", kind: .document,
                                    title: name, link: url.absoluteString)
    }

    static func documentText(_ url: URL) async throws -> String {
        switch url.pathExtension.lowercased() {
        case "pdf":
            guard let document = PDFDocument(url: url) else { return "" }
            return (0..<document.pageCount).compactMap { index in
                document.page(at: index)?.string.map { "Page \(index + 1):\n\($0)" }
            }.joined(separator: "\n")
        case "docx", "doc", "rtf", "rtfd", "odt", "html", "htm", "webarchive":
            return try await run("/usr/bin/textutil", ["-convert", "txt", "-stdout", url.path], in: nil)
        case "xlsx":
            return try await spreadsheetText(url)
        default:
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            return String(decoding: data.prefix(2_000_000), as: UTF8.self)
        }
    }

    /// Each sheet's cells, one row per line, from the workbook's XML.
    static func spreadsheetText(_ url: URL) async throws -> String {
        let entries = try await run("/usr/bin/unzip", ["-Z1", url.path], in: nil).split(separator: "\n").map(String.init)
        let shared = entries.contains("xl/sharedStrings.xml")
            ? try await run("/usr/bin/unzip", ["-p", url.path, "xl/sharedStrings.xml"], in: nil) : ""
        let strings = XLSX.sharedStrings(shared)
        var sheets: [String] = []
        let sheetFiles = entries.filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        for (index, file) in sheetFiles.prefix(6).enumerated() {
            let xml = try await run("/usr/bin/unzip", ["-p", url.path, file], in: nil)
            sheets.append("Sheet \(index + 1):\n" + XLSX.rows(xml, strings: strings).joined(separator: "\n"))
        }
        return sheets.joined(separator: "\n\n")
    }

    /// Windows of text around the query's words, most matches first, or the
    /// start when nothing matches.
    static func excerpt(of text: String, query: String, limit: Int = outputCharacters) -> String {
        let clean = text.replacingOccurrences(of: "\r", with: "")
        let words = PersonalContextSelection.contentWords(query)
        guard !words.isEmpty else { return String(clean.prefix(limit)) }
        let lines = clean.components(separatedBy: "\n")
        var scored: [(index: Int, score: Int)] = []
        for (index, line) in lines.enumerated() {
            let lineWords = PersonalContextSelection.contentWords(line)
            let score = words.intersection(lineWords).count
            if score > 0 { scored.append((index, score)) }
        }
        guard !scored.isEmpty else { return String(clean.prefix(limit)) }
        var keep = Set<Int>()
        for hit in scored.sorted(by: { $0.score > $1.score }).prefix(12) {
            for index in max(0, hit.index - 3)...min(lines.count - 1, hit.index + 3) { keep.insert(index) }
        }
        var out = ""
        var previous = -2
        for index in keep.sorted() {
            if index != previous + 1 { out += out.isEmpty ? "" : "\n…\n" }
            out += lines[index] + "\n"
            previous = index
            if out.count > limit { break }
        }
        return String(out.prefix(limit))
    }

    // MARK: - Code

    static func searchCode(_ query: String, in place: LiveAnswerPlace) async throws -> LiveAnswerToolOutput {
        guard !query.isEmpty else { return .message("Give a query.") }
        let output = try await git(["grep", "-n", "-I", "-i", "-F", "--max-count=4", "-e", query], in: place.url, allowFailure: true)
        let hits = output.split(separator: "\n").prefix(40).map { String($0.prefix(240)) }
        guard !hits.isEmpty else { return .message("No tracked file in \(place.name) contains “\(query)”.") }
        let lines = hits.compactMap { hit -> LiveAnswerLine? in
            let parts = hit.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let number = Int(parts[1]) else { return nil }
            return LiveAnswerLine(text: hit, title: "\(parts[0]):\(number)", link: place.link(path: String(parts[0]), line: number))
        }
        return LiveAnswerToolOutput(text: hits.joined(separator: "\n"), kind: .code, title: place.name,
                                    lines: lines)
    }

    static func readFile(_ path: String, from start: Int, to end: Int, in place: LiveAnswerPlace) async throws -> LiveAnswerToolOutput {
        let clean = path.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let tracked = (try? await git(["ls-files", "--error-unmatch", "--", clean], in: place.url)) != nil
        let url = place.url.appendingPathComponent(clean).standardizedFileURL
        guard tracked, url.path.hasPrefix(place.url.path + "/"), !isSecret(url) else {
            return .message("\(clean) isn't a tracked file in \(place.name).")
        }
        let all = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        let first = max(1, min(start, all.count))
        let last = max(first, min(end, first + 119, all.count))
        let numbered = (first...last).map { LiveAnswerLine(text: String(format: "%5d| %@", $0, all[$0 - 1]),
                                                           title: "\(clean):\($0)", link: place.link(path: clean, line: $0)) }
        return LiveAnswerToolOutput(text: "\(clean) lines \(first)–\(last) of \(all.count)\n" + numbered.map(\.text).joined(separator: "\n"),
                                    kind: .code, title: "\(clean):\(first)", link: place.link(path: clean, line: first),
                                    lines: numbered)
    }

    static func recentCommits(query: String, path: String, in place: LiveAnswerPlace) async throws -> LiveAnswerToolOutput {
        var arguments = ["log", "-n", "15", "--date=short", "--format=%h%x09%ad%x09%an%x09%s"]
        if !query.isEmpty { arguments += ["-i", "--grep=\(query)"] }
        if !path.isEmpty { arguments += ["--", path] }
        let output = try await git(arguments, in: place.url, allowFailure: true)
        let lines = output.split(separator: "\n").map { row -> LiveAnswerLine in
            let fields = row.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            let sha = fields.first ?? ""
            let text = fields.joined(separator: " · ")
            let link = place.gitHub.map { "https://github.com/\($0)/commit/\(sha)" }
            return LiveAnswerLine(text: text, title: "commit \(sha)", link: link)
        }
        guard !lines.isEmpty else { return .message("No commits match.") }
        return LiveAnswerToolOutput(text: lines.map(\.text).joined(separator: "\n"), kind: .commit,
                                    title: "\(place.name) commits", lines: lines)
    }

    // MARK: - GitHub

    static func searchGitHub(_ query: String, issues: Bool, in place: LiveAnswerPlace) async throws -> LiveAnswerToolOutput {
        let noun = issues ? "issues" : "pull requests"
        var arguments = [issues ? "issue" : "pr", "list", "--state", "all", "--limit", "8",
                         "--json", issues ? "number,title,state,updatedAt,url" : "number,title,state,isDraft,mergedAt,updatedAt,url"]
        if !query.isEmpty { arguments += ["--search", query] }
        let json = try await gh(arguments, in: place)
        guard let rows = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]], !rows.isEmpty else {
            return .message("No \(noun) match.")
        }
        let lines = rows.map { row -> LiveAnswerLine in
            let number = row["number"] as? Int ?? 0
            var state = (row["state"] as? String ?? "").uppercased()
            if row["isDraft"] as? Bool == true { state += " (draft)" }
            var text = "#\(number) \(state) “\(row["title"] as? String ?? "")”"
            if let merged = row["mergedAt"] as? String, !merged.isEmpty { text += " · merged \(merged.prefix(10))" }
            if let updated = row["updatedAt"] as? String { text += " · updated \(updated.prefix(10))" }
            return LiveAnswerLine(text: text, title: "#\(number)", link: row["url"] as? String)
        }
        return LiveAnswerToolOutput(text: lines.map(\.text).joined(separator: "\n"), kind: issues ? .issue : .pullRequest,
                                    title: place.name, lines: lines)
    }

    static func viewOnGitHub(_ number: Int, issues: Bool, in place: LiveAnswerPlace) async throws -> LiveAnswerToolOutput {
        let fields = issues ? "number,title,state,url,body,author,updatedAt"
            : "number,title,state,isDraft,mergedAt,url,body,reviewDecision,statusCheckRollup,headRefName"
        let json = try await gh([issues ? "issue" : "pr", "view", String(number), "--json", fields], in: place)
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            return .message("#\(number) wasn't found.")
        }
        var lines = ["#\(number) \((object["state"] as? String ?? "").uppercased())\(object["isDraft"] as? Bool == true ? " (draft)" : "") “\(object["title"] as? String ?? "")”"]
        if let merged = object["mergedAt"] as? String, !merged.isEmpty { lines.append("Merged \(merged.prefix(10))") }
        if let branch = object["headRefName"] as? String { lines.append("Branch \(branch)") }
        if let review = object["reviewDecision"] as? String, !review.isEmpty { lines.append("Review: \(review.lowercased())") }
        if let checks = object["statusCheckRollup"] as? [[String: Any]], !checks.isEmpty {
            var counts: [String: Int] = [:]
            var failing: [String] = []
            for check in checks {
                let result = ((check["conclusion"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? check["status"] as? String ?? "PENDING").uppercased()
                counts[result, default: 0] += 1
                if result == "FAILURE", let name = check["name"] as? String { failing.append(name) }
            }
            let summary = counts.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key.lowercased())" }.joined(separator: ", ")
            lines.append("Checks: \(summary)" + (failing.isEmpty ? "" : "; failing: \(failing.joined(separator: ", "))"))
        }
        if let body = object["body"] as? String, !body.isEmpty { lines.append(String(body.prefix(1_500))) }
        return LiveAnswerToolOutput(text: lines.joined(separator: "\n"), kind: issues ? .issue : .pullRequest,
                                    title: "#\(number)", link: object["url"] as? String)
    }

    // MARK: - Paths

    static func isSecret(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        let secrets = [".env", ".pem", ".key", ".p12", ".pfx", ".keychain", "id_rsa", "id_ed25519", ".netrc", "credentials"]
        return secrets.contains { name == $0 || name.hasSuffix($0) || name.hasPrefix(".env") }
    }

    /// Inside an approved folder, no hidden component, not secret-looking,
    /// and a type `read_document` can read.
    static func isReadable(_ url: URL, places: [LiveAnswerPlace]) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard let place = places.first(where: { path.hasPrefix($0.url.resolvingSymlinksInPath().path + "/") }) else { return false }
        let relative = path.dropFirst(place.url.resolvingSymlinksInPath().path.count + 1)
        guard !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") || $0 == "node_modules" }) else { return false }
        return !isSecret(url) && readableExtensions.contains(url.pathExtension.lowercased())
    }

    static func resolve(_ path: String, places: [LiveAnswerPlace]) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath).standardizedFileURL
        }
        for place in places {
            // "Folder/sub/file.pdf" names the folder first; a bare path is
            // looked up in each folder.
            let relative = trimmed.hasPrefix(place.name + "/") ? String(trimmed.dropFirst(place.name.count + 1)) : trimmed
            let url = place.url.appendingPathComponent(relative).standardizedFileURL
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    static func displayPath(_ url: URL, places: [LiveAnswerPlace]) -> String {
        let path = url.standardizedFileURL.path
        guard let place = places.first(where: { path.hasPrefix($0.url.path + "/") }) else { return url.lastPathComponent }
        return place.name + "/" + path.dropFirst(place.url.path.count + 1)
    }

    static func files(in folder: URL, limit: Int) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var found: [URL] = []
        for case let url as URL in enumerator {
            if url.lastPathComponent == "node_modules" { enumerator.skipDescendants(); continue }
            if readableExtensions.contains(url.pathExtension.lowercased()) { found.append(url) }
            if found.count >= limit { break }
        }
        return found
    }

    // MARK: - Commands

    enum CommandError: LocalizedError {
        case failed(String)
        case missing(String)
        var errorDescription: String? {
            switch self {
            case .failed(let detail): detail
            case .missing(let tool): "\(tool) isn't installed on this Mac."
            }
        }
    }

    static func git(_ arguments: [String], in folder: URL, allowFailure: Bool = false) async throws -> String {
        try await run("/usr/bin/git", ["-C", folder.path] + arguments, in: nil, allowFailure: allowFailure,
                      extra: ["GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0"])
    }

    static func gh(_ arguments: [String], in place: LiveAnswerPlace) async throws -> String {
        guard let gh = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw CommandError.missing("The GitHub CLI (gh)")
        }
        return try await run(gh, arguments, in: place.url,
                             extra: ["GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1", "NO_COLOR": "1"])
    }

    static func run(_ executable: String, _ arguments: [String], in folder: URL?, allowFailure: Bool = false,
                    extra: [String: String] = [:]) async throws -> String {
        let base = ProcessInfo.processInfo.environment
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
                           "LANG": "en_US.UTF-8"]
        for key in ["HOME", "USER", "TMPDIR"] { environment[key] = base[key] }
        environment.merge(extra) { $1 }
        let output: ClaudeCodeProcess.Output
        do {
            output = try await ClaudeCodeProcess.run(executable: URL(fileURLWithPath: executable), arguments: arguments,
                                                     environment: environment, workingDirectory: folder,
                                                     timeout: commandTimeout)
        } catch ClaudePlanError.notInstalled {
            throw CommandError.missing((executable as NSString).lastPathComponent)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CommandError.failed("\((executable as NSString).lastPathComponent) didn't finish in time.")
        }
        guard output.status == 0 || allowFailure else {
            throw CommandError.failed(output.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n").last.map(String.init) ?? "exit \(output.status)")
        }
        return String(decoding: output.stdout.prefix(400_000), as: UTF8.self)
    }
}

/// Just enough of the .xlsx format to read cell values: shared strings,
/// inline strings, and numbers, by row.
enum XLSX {
    static func sharedStrings(_ xml: String) -> [String] {
        matches(of: #"<si>(.*?)</si>"#, in: xml).map { item in
            matches(of: #"<t[^>]*>(.*?)</t>"#, in: item).joined().xmlUnescaped
        }
    }

    static func rows(_ xml: String, strings: [String]) -> [String] {
        matches(of: #"<row[^>]*>(.*?)</row>"#, in: xml).compactMap { row in
            let cells = captures(of: #"<c ([^>]*?)(?:/>|>(.*?)</c>)"#, in: row, groups: 2).compactMap { groups -> String? in
                let attributes = groups[0], body = groups[1]
                let type = matches(of: #"t="([^"]+)""#, in: attributes).first
                if type == "inlineStr" { return matches(of: #"<t[^>]*>(.*?)</t>"#, in: body).joined().xmlUnescaped }
                guard let value = matches(of: #"<v>(.*?)</v>"#, in: body).first else { return nil }
                if type == "s" { return Int(value).flatMap { strings.indices.contains($0) ? strings[$0] : nil } }
                return value.xmlUnescaped
            }
            return cells.isEmpty ? nil : cells.joined(separator: " | ")
        }
    }

    private static func captures(of pattern: String, in text: String, groups: Int) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { match in
            (1...groups).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }

    private static func matches(of pattern: String, in text: String) -> [String] {
        captures(of: pattern, in: text, groups: 1).map { $0[0] }
    }
}

private extension String {
    var xmlUnescaped: String {
        replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
