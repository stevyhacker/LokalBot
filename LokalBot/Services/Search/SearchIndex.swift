import Foundation
import SQLite3

final class SearchIndex {

    private static let documentRowsMigration = "search-document-rows-v1"
    private static let notesOutcomesMigration = "search-notes-outcomes-v1"

    static let sourceFileNames = [
        "meta.json", "transcript.json", "summary.md", MeetingNotes.fileName,
        MeetingOutcomes.fileName, MeetingOutcomeState.fileName,
    ]

    enum Kind: String, Sendable {
        case title, segment, summary, notes, outcome
    }

    struct Hit: Identifiable, Sendable {
        let id = UUID()
        let meetingID: UUID
        let kind: Kind
        let start: TimeInterval
        let snippet: String
        let speaker: String
        var isSemantic = false
        var sourceText: String?
    }

    private let database: SQLiteDatabase?
    private var locallyDeletedMeetingIDs: Set<UUID> = []

    init(databaseURL: URL, readOnly: Bool = false) {
        guard let database = SQLiteDatabase(url: databaseURL, readOnly: readOnly) else {
            assertionFailure("SearchIndex: cannot open \(databaseURL.path)")
            self.database = nil
            return
        }
        self.database = database
        guard !readOnly else { return }
        database.exec("""
            CREATE TABLE IF NOT EXISTS indexed_meetings (
                meeting_id TEXT PRIMARY KEY,
                source_mtime REAL NOT NULL
            );
            CREATE VIRTUAL TABLE IF NOT EXISTS docs USING fts5(
                text,
                meeting_id UNINDEXED,
                kind UNINDEXED,
                start UNINDEXED,
                speaker UNINDEXED,
                tokenize='unicode61 remove_diacritics 2'
            );
            CREATE TABLE IF NOT EXISTS search_document_rows (
                doc_rowid INTEGER PRIMARY KEY,
                meeting_id TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_search_document_rows_meeting_id
                ON search_document_rows(meeting_id);
            CREATE TABLE IF NOT EXISTS search_index_migrations (
                name TEXT PRIMARY KEY
            );
            CREATE TABLE IF NOT EXISTS deleted_meetings (
                meeting_id TEXT PRIMARY KEY,
                deleted_at REAL NOT NULL
            );
            """)
        Self.backfillDocumentRowsIfNeeded(in: database)
        Self.scheduleNotesOutcomesBackfillIfNeeded(in: database)
        _ = reconcileDeletedMeetings()
    }

    func reindexAll(_ meetings: [Meeting], storage: StorageManager) {
        for meeting in meetings {
            guard !Task.isCancelled else { return }
            reindex(meeting, storage: storage)
        }
    }

    func reindex(_ meeting: Meeting, storage: StorageManager,
                 beforeTransaction: (() -> Void)? = nil) {
        guard !locallyDeletedMeetingIDs.contains(meeting.id) else { return }
        let folder = meeting.folderURL(in: storage)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }
        let mtime = Self.latestMtime(in: folder)
        if let indexed = indexedMtime(of: meeting.id), indexed >= mtime,
           let database, (try? Self.hasRemovedSource(meetingID: meeting.id.uuidString,
                                                     folder: folder, in: database)) == false {
            return
        }

        var documents = [Document(text: "\(meeting.title) \(meeting.appName)",
                                  kind: .title, start: 0, speaker: "")]

        if let data = try? Data(contentsOf: folder.appendingPathComponent("transcript.json")),
           let transcript = try? JSONDecoder().decode(Transcript.self, from: data) {
            for segment in transcript.segments {
                documents.append(Document(
                    text: segment.text,
                    kind: .segment,
                    start: segment.start,
                    speaker: transcript.displaySpeaker(for: segment.speaker)))
            }
        }
        if let summary = try? String(contentsOf: folder.appendingPathComponent("summary.md"),
                                     encoding: .utf8) {
            documents.append(Document(text: summary, kind: .summary, start: 0, speaker: ""))
        }
        if let notes = MeetingNotes.load(from: folder) {
            documents.append(Document(text: notes, kind: .notes, start: 0, speaker: ""))
        }
        documents += Self.outcomeTexts(for: meeting, root: storage.rootURL).map {
            Document(text: $0, kind: .outcome, start: 0, speaker: "")
        }
        documents = documents.compactMap { document in
            let text = document.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : Document(text: text, kind: document.kind,
                                                 start: document.start, speaker: document.speaker)
        }

        guard !Task.isCancelled, let database else { return }
        let meetingID = meeting.id.uuidString
        beforeTransaction?()
        guard !Task.isCancelled else { return }
        database.transaction {
            do {
                guard try !database.hasRowChecked(
                    "SELECT 1 FROM deleted_meetings WHERE meeting_id = ?1",
                    bind: [meetingID]),
                      FileManager.default.fileExists(atPath: folder.path) else { return true }
                if let indexed = try database.firstDoubleChecked(
                    "SELECT source_mtime FROM indexed_meetings WHERE meeting_id = ?1",
                    bind: [meetingID]), indexed >= mtime,
                   try !Self.hasRemovedSource(meetingID: meetingID, folder: folder, in: database) {
                    return true
                }
            } catch {
                return false
            }
            guard Self.deleteDocuments(for: meetingID, in: database) else { return false }
            let inserted = database.withStatement(
                "INSERT INTO docs (text, meeting_id, kind, start, speaker) VALUES (?1, ?2, ?3, ?4, ?5)"
            ) { documentStatement in
                database.withStatement(
                    "INSERT INTO search_document_rows (doc_rowid, meeting_id) VALUES (?1, ?2)"
                ) { mappingStatement in
                    for document in documents {
                        guard database.run(documentStatement, bind: [
                            document.text, meetingID, document.kind.rawValue,
                            document.start, document.speaker,
                        ]), database.run(mappingStatement, bind: [
                            database.lastInsertRowID(), meetingID,
                        ]) else { return false }
                    }
                    return true
                } ?? false
            } ?? false
            guard inserted else { return false }
            return database.run(
                "INSERT OR REPLACE INTO indexed_meetings (meeting_id, source_mtime) VALUES (?1, ?2)",
                bind: [meetingID, mtime])
        }
    }

    @discardableResult
    func remove(_ meetingID: UUID) -> Bool {
        noteDeletion(meetingID)
        guard let database else { return false }
        let id = meetingID.uuidString
        let marked = database.transaction {
            database.run(
                "INSERT OR IGNORE INTO deleted_meetings (meeting_id, deleted_at) VALUES (?1, ?2)",
                bind: [id, Date().timeIntervalSince1970])
        }
        guard marked else { return false }
        return database.transaction {
            Self.deleteDocuments(for: id, in: database)
                && database.run("DELETE FROM indexed_meetings WHERE meeting_id = ?1", bind: [id])
        }
    }

    func noteDeletion(_ meetingID: UUID) {
        locallyDeletedMeetingIDs.insert(meetingID)
    }

    func noteRestoration(_ meetingID: UUID) {
        locallyDeletedMeetingIDs.remove(meetingID)
    }

    static func clearStaleTombstones(liveMeetingIDs: Set<UUID>, databaseURL: URL) -> Set<UUID> {
        guard !liveMeetingIDs.isEmpty,
              let database = SQLiteDatabase(url: databaseURL),
              database.hasRow("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'deleted_meetings'")
        else { return [] }
        var cleared: Set<UUID> = []
        let succeeded = database.transaction {
            for id in liveMeetingIDs where database.hasRow(
                "SELECT 1 FROM deleted_meetings WHERE meeting_id = ?1", bind: [id.uuidString]) {
                guard database.run("DELETE FROM deleted_meetings WHERE meeting_id = ?1",
                                   bind: [id.uuidString]) else { return false }
                cleared.insert(id)
            }
            return true
        }
        return succeeded ? cleared : []
    }

    static func restoreMergedSource(_ meetingID: UUID, from mergedID: UUID,
                                    databaseURL: URL) throws {
        guard let database = SQLiteDatabase(url: databaseURL) else {
            throw SQLiteDatabase.DatabaseError.unavailable(path: databaseURL.path)
        }
        let restored = database.transaction {
            database.exec("""
                CREATE TABLE IF NOT EXISTS deleted_meetings (
                    meeting_id TEXT PRIMARY KEY,
                    deleted_at REAL NOT NULL
                );
                """)
                && database.run(
                    "INSERT OR IGNORE INTO deleted_meetings (meeting_id, deleted_at) VALUES (?1, ?2)",
                    bind: [mergedID.uuidString, Date().timeIntervalSince1970])
                && database.run("DELETE FROM deleted_meetings WHERE meeting_id = ?1",
                                bind: [meetingID.uuidString])
        }
        guard restored else {
            throw database.lastError ?? SQLiteDatabase.DatabaseError.unavailable(path: databaseURL.path)
        }
    }

    @discardableResult
    func reconcileDeletedMeetings() -> Bool {
        guard let database else { return false }
        return database.transaction {
            database.run("""
                DELETE FROM docs
                WHERE rowid IN (
                    SELECT doc_rowid FROM search_document_rows
                    WHERE meeting_id IN (SELECT meeting_id FROM deleted_meetings)
                )
                """)
                && database.run("""
                    DELETE FROM search_document_rows
                    WHERE meeting_id IN (SELECT meeting_id FROM deleted_meetings)
                    """)
                && database.run("""
                    DELETE FROM indexed_meetings
                    WHERE meeting_id IN (SELECT meeting_id FROM deleted_meetings)
                    """)
        }
    }

    func search(_ query: String, kind: Kind? = nil, limit: Int = 60,
                matchAll: Bool = true, dropStopWords: Bool = false,
                meetingIDs: Set<UUID>? = nil) -> [Hit] {
        guard limit > 0 else { return [] }
        if let meetingIDs, meetingIDs.isEmpty { return [] }
        if CJKSearch.containsCJK(query) {
            return substringSearch(query, kind: kind, limit: limit, matchAll: matchAll,
                                   dropStopWords: dropStopWords, meetingIDs: meetingIDs,
                                   cjkRowsOnly: false)
        }
        let hits = ftsSearch(query, kind: kind, limit: limit, matchAll: matchAll,
                             dropStopWords: dropStopWords, meetingIDs: meetingIDs)
        guard hits.isEmpty else { return hits }
        return substringSearch(query, kind: kind, limit: limit, matchAll: matchAll,
                               dropStopWords: dropStopWords, meetingIDs: meetingIDs,
                               cjkRowsOnly: true)
    }

    private func ftsSearch(_ query: String, kind: Kind?, limit: Int, matchAll: Bool,
                           dropStopWords: Bool, meetingIDs: Set<UUID>?) -> [Hit] {
        guard let match = Self.ftsQuery(from: query, matchAll: matchAll,
                                        dropStopWords: dropStopWords),
              let database else { return [] }
        var sql = """
            SELECT meeting_id, kind, start, speaker,
                   snippet(docs, 0, '«', '»', '…', 14), text
            FROM docs WHERE docs MATCH ?1
              AND NOT EXISTS (
                  SELECT 1 FROM deleted_meetings AS deleted
                  WHERE deleted.meeting_id = docs.meeting_id
              )
            """
        var values: [Any] = [match]
        if let kind {
            values.append(kind.rawValue)
            sql += " AND kind = ?\(values.count)"
        }
        if let meetingIDs {
            let sortedIDs = meetingIDs.map(\.uuidString).sorted()
            let placeholders = sortedIDs.map { id -> String in
                values.append(id)
                return "?\(values.count)"
            }
            sql += " AND meeting_id IN (\(placeholders.joined(separator: ", ")))"
        }
        sql += " ORDER BY rank LIMIT \(limit)"
        return database.query(sql, bind: values) { statement in
            guard let idText = sqlite3_column_text(statement, 0),
                  let meetingID = UUID(uuidString: String(cString: idText)),
                  let kindText = sqlite3_column_text(statement, 1),
                  let kind = Kind(rawValue: String(cString: kindText)),
                  let snippetText = sqlite3_column_text(statement, 4) else { return nil }
            let speaker = sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? ""
            return Hit(meetingID: meetingID, kind: kind,
                       start: sqlite3_column_double(statement, 2),
                       snippet: String(cString: snippetText),
                       speaker: speaker,
                       sourceText: sqlite3_column_text(statement, 5).map { String(cString: $0) })
        }.filter { !locallyDeletedMeetingIDs.contains($0.meetingID) }
    }

    func matchingMeetingIDs(_ query: String) -> Set<UUID> {
        if CJKSearch.containsCJK(query) { return substringMeetingIDs(query, cjkRowsOnly: false) }
        guard let match = Self.ftsQuery(from: query, matchAll: true, dropStopWords: false),
              let database else { return [] }
        let ids: [UUID] = database.query("""
            SELECT DISTINCT meeting_id FROM docs WHERE docs MATCH ?1
              AND NOT EXISTS (
                  SELECT 1 FROM deleted_meetings AS deleted
                  WHERE deleted.meeting_id = docs.meeting_id
              )
            """, bind: [match]) { statement in
            sqlite3_column_text(statement, 0).flatMap { UUID(uuidString: String(cString: $0)) }
        }
        let found = Set(ids).subtracting(locallyDeletedMeetingIDs)
        return found.isEmpty ? substringMeetingIDs(query, cjkRowsOnly: true) : found
    }

    static func substringTerms(_ query: String, matchAll: Bool, dropStopWords: Bool) -> [String] {
        var terms = matchAll ? CJKSearch.terms(from: query) : CJKSearch.relaxedTerms(from: query)
        if dropStopWords {
            let content = terms.filter { !stopWords.contains($0.lowercased()) }
            if !content.isEmpty { terms = content }
        }
        return terms
    }

    private static func substringConditions(terms: [String], matchAll: Bool, cjkRowsOnly: Bool,
                                            values: inout [Any]) -> [String] {
        let termClauses = terms.map { term -> String in
            values.append(CJKSearch.likePattern(for: term))
            return "text LIKE ?\(values.count) \(CJKSearch.likeEscapeClause)"
        }
        var conditions = ["(" + termClauses.joined(separator: matchAll ? " AND " : " OR ") + ")"]
        if cjkRowsOnly {
            values.append(CJKSearch.rowGlobPattern)
            conditions.append("text GLOB ?\(values.count)")
        }
        conditions.append("""
            NOT EXISTS (
                SELECT 1 FROM deleted_meetings AS deleted
                WHERE deleted.meeting_id = docs.meeting_id
            )
            """)
        return conditions
    }

    private func substringSearch(_ query: String, kind: Kind?, limit: Int, matchAll: Bool,
                                 dropStopWords: Bool, meetingIDs: Set<UUID>?,
                                 cjkRowsOnly: Bool) -> [Hit] {
        let terms = Self.substringTerms(query, matchAll: matchAll, dropStopWords: dropStopWords)
        guard !terms.isEmpty, let database else { return [] }
        var values: [Any] = []
        var conditions = Self.substringConditions(terms: terms, matchAll: matchAll,
                                                  cjkRowsOnly: cjkRowsOnly, values: &values)
        if let kind {
            values.append(kind.rawValue)
            conditions.append("kind = ?\(values.count)")
        }
        if let meetingIDs {
            let placeholders = meetingIDs.map(\.uuidString).sorted().map { id -> String in
                values.append(id)
                return "?\(values.count)"
            }
            conditions.append("meeting_id IN (\(placeholders.joined(separator: ", ")))")
        }
        let fetchLimit = matchAll ? limit : max(limit * 4, 200)
        let rows: [(meetingID: UUID, kind: Kind, start: TimeInterval, speaker: String, text: String)] =
            database.query("""
                SELECT meeting_id, kind, start, speaker, text FROM docs
                WHERE \(conditions.joined(separator: " AND "))
                ORDER BY length(text), rowid DESC
                LIMIT \(fetchLimit)
                """, bind: values) { statement in
                guard let idText = sqlite3_column_text(statement, 0),
                      let meetingID = UUID(uuidString: String(cString: idText)),
                      let kindText = sqlite3_column_text(statement, 1),
                      let kind = Kind(rawValue: String(cString: kindText)),
                      let body = sqlite3_column_text(statement, 4) else { return nil }
                return (meetingID, kind, sqlite3_column_double(statement, 2),
                        sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? "",
                        String(cString: body))
            }
        let ranked = matchAll ? rows : rows.enumerated().sorted { left, right in
            let leftCount = CJKSearch.matchedTermCount(in: left.element.text, terms: terms)
            let rightCount = CJKSearch.matchedTermCount(in: right.element.text, terms: terms)
            return leftCount == rightCount ? left.offset < right.offset : leftCount > rightCount
        }.map(\.element)
        let deleted = locallyDeletedMeetingIDs
        var hits: [Hit] = []
        for row in ranked where !deleted.contains(row.meetingID) {
            guard let snippet = CJKSearch.snippet(in: row.text, terms: terms) else { continue }
            hits.append(Hit(meetingID: row.meetingID, kind: row.kind, start: row.start,
                            snippet: snippet, speaker: row.speaker, sourceText: row.text))
            if hits.count == limit { break }
        }
        return hits
    }

    private func substringMeetingIDs(_ query: String, cjkRowsOnly: Bool) -> Set<UUID> {
        let terms = Self.substringTerms(query, matchAll: true, dropStopWords: false)
        guard !terms.isEmpty, let database else { return [] }
        var values: [Any] = []
        let conditions = Self.substringConditions(terms: terms, matchAll: true,
                                                  cjkRowsOnly: cjkRowsOnly, values: &values)
        let ids: [UUID] = database.query("""
            SELECT DISTINCT meeting_id FROM docs WHERE \(conditions.joined(separator: " AND "))
            """, bind: values) { statement in
            sqlite3_column_text(statement, 0).flatMap { UUID(uuidString: String(cString: $0)) }
        }
        return Set(ids).subtracting(locallyDeletedMeetingIDs)
    }

    func semanticPassage(meetingID: UUID, start: TimeInterval, text: String, query: String) -> Hit? {
        guard let database, !locallyDeletedMeetingIDs.contains(meetingID) else { return nil }
        let candidates: [(String, Kind, TimeInterval, String)] = database.query("""
            SELECT text, kind, start, speaker FROM search_document_rows AS source
            JOIN docs ON docs.rowid = source.doc_rowid
            WHERE source.meeting_id = ?1
              AND (kind IN ('summary', 'notes') OR (kind = 'segment' AND start >= ?2 AND start < ?3))
              AND NOT EXISTS (SELECT 1 FROM deleted_meetings WHERE meeting_id = ?1)
            LIMIT 100
            """, bind: [meetingID.uuidString, start, start + 120]) { statement in
                guard let body = sqlite3_column_text(statement, 0),
                      let rawKind = sqlite3_column_text(statement, 1),
                      let kind = Kind(rawValue: String(cString: rawKind)) else { return nil }
                return (String(cString: body), kind, sqlite3_column_double(statement, 2),
                        sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? "")
            }
        let fragments = text.split(separator: "\n").map { line -> String in
            let line = String(line)
            return line.range(of: ": ").map { String(line[$0.upperBound...]) } ?? line
        }.filter { !$0.isEmpty }
        let bodyText = text.hasPrefix(EmbeddingIndex.notesChunkMarker)
            ? String(text.dropFirst(EmbeddingIndex.notesChunkMarker.count)) : text
        let summaries = candidates.filter {
            ($0.1 == .summary || $0.1 == .notes) && $0.0.contains(String(bodyText.prefix(100)))
        }
        let matching = summaries.isEmpty ? candidates.filter { candidate in
            candidate.1 == .segment && fragments.contains { candidate.0.contains(String($0.prefix(80))) }
        } : summaries
        return matching.compactMap { match -> Hit? in
            guard let snippet = RecallPassage.excerpt(match.0, query: query) else { return nil }
            return Hit(meetingID: meetingID, kind: match.1, start: match.2,
                       snippet: snippet, speaker: match.3, isSemantic: true)
        }.sorted {
            let left = RecallPassage.queryMatchCount($0.snippet, query: query)
            let right = RecallPassage.queryMatchCount($1.snippet, query: query)
            return left == right ? $0.start < $1.start : left > right
        }.first
    }

    static let stopWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "if", "of", "to", "in", "on", "at",
        "for", "with", "about", "as", "by", "from", "into", "is", "are", "was",
        "were", "be", "been", "being", "do", "does", "did", "doing", "have", "has",
        "had", "what", "when", "where", "who", "whom", "which", "why", "how",
        "we", "i", "you", "he", "she", "it", "they", "me", "us", "them", "my",
        "our", "your", "this", "that", "these", "those", "can", "could", "would",
        "should", "will", "shall", "may", "might", "must", "any", "some", "there",
    ]

    static func ftsQuery(from raw: String, matchAll: Bool = true,
                         dropStopWords: Bool = false) -> String? {
        var terms = raw.split(whereSeparator: \.isWhitespace)
            .map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { !$0.isEmpty }
        if dropStopWords {
            let content = terms.filter { !stopWords.contains($0.lowercased()) }
            if !content.isEmpty { terms = content }
        }
        guard !terms.isEmpty else { return nil }
        guard matchAll else {
            return terms.map { "\"\($0)\"" }.joined(separator: " OR ")
        }
        return terms.enumerated()
            .map { index, term in
                index == terms.count - 1 ? "\"\(term)\" *" : "\"\(term)\""
            }
            .joined(separator: " ")
    }

    private struct Document {
        let text: String
        let kind: Kind
        let start: TimeInterval
        let speaker: String
    }

    private static func backfillDocumentRowsIfNeeded(in database: SQLiteDatabase) {
        guard !database.hasRow(
            "SELECT 1 FROM search_index_migrations WHERE name = ?1",
            bind: [documentRowsMigration]) else { return }
        database.transaction {
            database.run("DELETE FROM search_document_rows")
                && database.run("""
                    INSERT INTO search_document_rows (doc_rowid, meeting_id)
                    SELECT rowid, meeting_id FROM docs
                    WHERE meeting_id IS NOT NULL AND meeting_id != ''
                    """)
                && database.run(
                    "INSERT INTO search_index_migrations (name) VALUES (?1)",
                    bind: [documentRowsMigration])
        }
    }

    static func outcomeTexts(for meeting: Meeting, root: URL) -> [String] {
        guard let projection = MeetingOutcomeProjection.load(for: meeting, root: root),
              !projection.isArchived else { return [] }
        let decisions = projection.outcomes.decisionRecords.map { "Decision: \($0.text)" }
        let actions = projection.actionReferences.map { reference -> String in
            var details: [String] = []
            if let owner = reference.owner?.trimmingCharacters(in: .whitespacesAndNewlines),
               !owner.isEmpty {
                details.append("owner \(owner)")
            }
            if let due = reference.due?.trimmingCharacters(in: .whitespacesAndNewlines),
               !due.isEmpty {
                details.append("due \(due)")
            }
            let suffix = details.isEmpty ? "" : " (\(details.joined(separator: ", ")))"
            return "Action: \(reference.text)\(suffix)"
        }
        let questions = projection.outcomes.openQuestions.map { "Open question: \($0)" }
        return decisions + actions + questions
    }

    private static let documentSources: [(kind: Kind, fileName: String)] = [
        (.segment, "transcript.json"), (.summary, "summary.md"),
        (.notes, MeetingNotes.fileName), (.outcome, MeetingOutcomes.fileName),
    ]

    static func hasRemovedSource(meetingID: String, folder: URL,
                                 in database: SQLiteDatabase) throws -> Bool {
        let indexedKinds: [String] = try database.queryChecked("""
            SELECT DISTINCT docs.kind FROM search_document_rows AS source
            JOIN docs ON docs.rowid = source.doc_rowid
            WHERE source.meeting_id = ?1
            """, bind: [meetingID]) { statement in
            sqlite3_column_text(statement, 0).map { String(cString: $0) }
        }
        return documentSources.contains { source in
            indexedKinds.contains(source.kind.rawValue)
                && !FileManager.default.fileExists(
                    atPath: folder.appendingPathComponent(source.fileName).path)
        }
    }

    private static func scheduleNotesOutcomesBackfillIfNeeded(in database: SQLiteDatabase) {
        guard !database.hasRow(
            "SELECT 1 FROM search_index_migrations WHERE name = ?1",
            bind: [notesOutcomesMigration]) else { return }
        database.transaction {
            database.run("UPDATE indexed_meetings SET source_mtime = 0")
                && database.run(
                    "INSERT INTO search_index_migrations (name) VALUES (?1)",
                    bind: [notesOutcomesMigration])
        }
    }

    private static func deleteDocuments(for meetingID: String,
                                        in database: SQLiteDatabase) -> Bool {
        database.run("""
            DELETE FROM docs
            WHERE rowid IN (
                SELECT doc_rowid FROM search_document_rows WHERE meeting_id = ?1
            )
            """, bind: [meetingID])
            && database.run(
                "DELETE FROM search_document_rows WHERE meeting_id = ?1",
                bind: [meetingID])
    }

    private func indexedMtime(of meetingID: UUID) -> TimeInterval? {
        database?.firstDouble("SELECT source_mtime FROM indexed_meetings WHERE meeting_id = ?1",
                              bind: [meetingID.uuidString])
    }

    private static func latestMtime(in folder: URL) -> TimeInterval {
        sourceFileNames.compactMap { name -> TimeInterval? in
            let url = folder.appendingPathComponent(name)
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            return (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970
        }.max() ?? 0
    }

}
