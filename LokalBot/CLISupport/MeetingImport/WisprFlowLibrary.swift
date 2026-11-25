import Foundation
import SQLite3

enum WisprFlowLibrary {
    struct DictionaryEntry: Equatable, Sendable {
        var phrase: String
        var replacement: String?
        var isSnippet: Bool?
        var isDeleted = false
        var isStarred = false
        var timesUsed = 0
        var lastUsed: String?
    }

    struct MeetingRecord: Equatable, Sendable {
        var id: String
        var title: String?
        var createdAt: String?
        var endedAt: Double?
        var recordedMs: Double?
        var summary: String?
        var speakerMap: String?
        var participantNames: String?
        var isDeleted = false
        var isTourDemo = false
    }

    static let defaultLocation = "~/Library/Application Support/Wispr Flow/flow.sqlite"
    static let databaseName = "flow.sqlite"

    static var defaultFolder: URL? {
        let folder = URL(fileURLWithPath: (defaultLocation as NSString).expandingTildeInPath).deletingLastPathComponent()
        return FileManager.default.fileExists(atPath: folder.path) ? folder : nil
    }

    static func databaseURL(for picked: URL) -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: picked.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return picked
        }
        let inside = picked.appendingPathComponent(databaseName)
        let beside = picked.deletingLastPathComponent().appendingPathComponent(databaseName)
        if !FileManager.default.fileExists(atPath: inside.path), FileManager.default.fileExists(atPath: beside.path) {
            return beside
        }
        return inside
    }

    static func dictionary(at picked: URL) throws -> [DictionaryEntry] {
        let database = try open(picked, requiring: "dictionary")
        let wanted = ["phrase", "replacement", "isSnippet", "isDeleted", "isStarred", "frequencyUsed", "lastUsed"]
        return database.records("Dictionary", wanted).compactMap { row in
            guard let phrase = row["phrase"] as? String else { return nil }
            return DictionaryEntry(
                phrase: phrase,
                replacement: (row["replacement"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                isSnippet: row.keys.contains("issnippet") ? flag(row["issnippet"]) : nil,
                isDeleted: flag(row["isdeleted"]),
                isStarred: flag(row["isstarred"]),
                timesUsed: Int(number(row["frequencyused"]) ?? 0),
                lastUsed: row["lastused"] as? String)
        }
    }

    static func meetings(at picked: URL) throws -> [MeetingRecord] {
        let database = try open(picked, requiring: "meetings")
        let wanted = ["id", "title", "createdAt", "endedAt", "recordedMs", "summary", "speakerMap", "participantNames",
                      "isDeleted", "isTourDemo"]
        return database.records("Meetings", wanted).compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            return MeetingRecord(
                id: id,
                title: row["title"] as? String,
                createdAt: row["createdat"] as? String,
                endedAt: number(row["endedat"]),
                recordedMs: number(row["recordedms"]),
                summary: row["summary"] as? String,
                speakerMap: row["speakermap"] as? String,
                participantNames: row["participantnames"] as? String,
                isDeleted: flag(row["isdeleted"]),
                isTourDemo: flag(row["istourdemo"]))
        }
    }

    private static func open(_ picked: URL, requiring table: String) throws -> WisprFlowDatabase {
        let url = databaseURL(for: picked)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ExternalImportError.notFound(url.path) }
        let database: WisprFlowDatabase
        do {
            database = try WisprFlowDatabase(url)
        } catch let failure as WisprFlowDatabase.Failure {
            throw ExternalImportError.unreadable(url.path, failure.reason)
        }
        let tables = database.tables()
        guard tables.contains(table), tables.contains("sequelizemeta") else {
            throw ExternalImportError.unreadable(url.path, "it isn't Wispr Flow's database")
        }
        return database
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let value as Int64: Double(value)
        case let value as Double: value
        case let value as String: Double(value)
        default: nil
        }
    }

    private static func flag(_ value: Any?) -> Bool {
        if let text = value as? String { return text == "1" || text.lowercased() == "true" }
        return (number(value) ?? 0) != 0
    }
}

private final class WisprFlowDatabase {
    struct Failure: Error {
        var reason: String
    }

    private let handle: OpaquePointer
    private let snapshot: URL?

    init(_ url: URL) throws {
        let fileManager = FileManager.default
        let log = URL(fileURLWithPath: url.path + "-wal")
        let logSize = (try? log.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        var target = url
        var parameters = "immutable=1"
        var snapshot: URL?
        if logSize > 0 {
            let folder = fileManager.temporaryDirectory
                .appendingPathComponent("lokalbot-import-wispr-db-\(UUID().uuidString)", isDirectory: true)
            do {
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
                snapshot = folder
                target = folder.appendingPathComponent(WisprFlowLibrary.databaseName)
                try fileManager.copyItem(at: url, to: target)
                try fileManager.copyItem(at: log, to: URL(fileURLWithPath: target.path + "-wal"))
                parameters = "mode=ro"
            } catch {
                if let snapshot { try? fileManager.removeItem(at: snapshot) }
                throw Failure(reason: "the database couldn't be copied for reading")
            }
        }
        let path = target.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target.path
        var connection: OpaquePointer?
        let status = sqlite3_open_v2("file:\(path)?\(parameters)", &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard status == SQLITE_OK, let connection else {
            sqlite3_close(connection)
            if let snapshot { try? fileManager.removeItem(at: snapshot) }
            throw Failure(reason: "the database couldn't be opened")
        }
        sqlite3_busy_timeout(connection, 2_000)
        handle = connection
        self.snapshot = snapshot
    }

    deinit {
        sqlite3_close(handle)
        if let snapshot { try? FileManager.default.removeItem(at: snapshot) }
    }

    func tables() -> Set<String> {
        Set(rows("SELECT name FROM sqlite_master WHERE type = 'table'").compactMap { ($0["name"] as? String)?.lowercased() })
    }

    func records(_ table: String, _ wanted: [String]) -> [[String: Any]] {
        var present: [String: String] = [:]
        for row in rows("PRAGMA table_info(\(quoted(table)))") {
            if let name = row["name"] as? String { present[name.lowercased()] = name }
        }
        let picked = wanted.compactMap { present[$0.lowercased()] }
        guard !picked.isEmpty else { return [] }
        return rows("SELECT \(picked.map(quoted).joined(separator: ", ")) FROM \(quoted(table))")
    }

    private func quoted(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private func rows(_ sql: String) -> [[String: Any]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        var result: [[String: Any]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String: Any] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                guard let name = sqlite3_column_name(statement, column).map({ String(cString: $0).lowercased() }) else { continue }
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER:
                    row[name] = sqlite3_column_int64(statement, column)
                case SQLITE_FLOAT:
                    row[name] = sqlite3_column_double(statement, column)
                case SQLITE_TEXT:
                    if let text = sqlite3_column_text(statement, column) { row[name] = String(cString: text) }
                default:
                    break
                }
            }
            result.append(row)
        }
        return result
    }
}
