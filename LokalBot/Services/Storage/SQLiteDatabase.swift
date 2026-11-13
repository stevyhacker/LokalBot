import Foundation
import SQLite3

/// Small SQLite wrapper shared by the app's indexes and durable queues.
///
/// The checked APIs preserve SQLite failures as typed errors. The legacy
/// boolean/empty-result APIs remain for source compatibility, but now log the
/// same failure instead of silently hiding it.
final class SQLiteDatabase {
    enum DatabaseError: Swift.Error, LocalizedError {
        case unavailable(path: String)
        case open(path: String, code: Int32, message: String)
        case configure(operation: String, code: Int32, message: String)
        case execute(sql: String, code: Int32, message: String)
        case prepare(sql: String, code: Int32, message: String)
        case bind(index: Int32, code: Int32, message: String)
        case reset(code: Int32, message: String)
        case step(sql: String?, code: Int32, message: String)
        case backup(code: Int32, message: String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let path):
                "SQLite database is unavailable at \(path)"
            case .open(let path, let code, let message):
                "SQLite open failed (\(code)) at \(path): \(message)"
            case .configure(let operation, let code, let message):
                "SQLite configuration failed for \(operation) (\(code)): \(message)"
            case .execute(let sql, let code, let message):
                "SQLite execute failed (\(code)): \(message) [\(Self.summary(sql))]"
            case .prepare(let sql, let code, let message):
                "SQLite prepare failed (\(code)): \(message) [\(Self.summary(sql))]"
            case .bind(let index, let code, let message):
                "SQLite bind failed at parameter \(index) (\(code)): \(message)"
            case .reset(let code, let message):
                "SQLite statement reset failed (\(code)): \(message)"
            case .step(let sql, let code, let message):
                "SQLite step failed (\(code)): \(message)"
                    + (sql.map { " [\(Self.summary($0))]" } ?? "")
            case .backup(let code, let message):
                "SQLite backup failed (\(code)): \(message)"
            }
        }

        private static func summary(_ sql: String) -> String {
            let singleLine = sql.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return String(singleLine.prefix(180))
        }
    }

    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private let db: OpaquePointer
    private(set) var lastError: DatabaseError?
    private var errorGeneration: UInt64 = 0

    init?(url: URL, readOnly: Bool = false) {
        var opened: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
            | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(url.path, &opened, flags, nil)
        guard result == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) }
                ?? String(cString: sqlite3_errstr(result))
            if let opened { sqlite3_close(opened) }
            let error = DatabaseError.open(path: url.path, code: result, message: message)
            AppLog.line(error.localizedDescription)
            return nil
        }
        sqlite3_extended_result_codes(opened, 1)

        let timeoutResult = sqlite3_busy_timeout(opened, 5_000)
        guard timeoutResult == SQLITE_OK else {
            let error = DatabaseError.configure(
                operation: "busy_timeout", code: timeoutResult,
                message: String(cString: sqlite3_errmsg(opened)))
            AppLog.line(error.localizedDescription)
            sqlite3_close(opened)
            return nil
        }

        // Multiple app components own independent connections to the same
        // database. WAL lets readers proceed during a writer transaction;
        // NORMAL keeps the durability/performance tradeoff appropriate for
        // locally reconstructible indexes and queues. Configure the raw handle
        // before assigning `db`, so a failed failable initializer owns exactly
        // one close path.
        for (operation, sql) in (readOnly ? [] : [
            ("journal_mode", "PRAGMA journal_mode=WAL;"),
            ("synchronous", "PRAGMA synchronous=NORMAL;"),
            ("foreign_keys", "PRAGMA foreign_keys=ON;"),
        ]) {
            var errorMessage: UnsafeMutablePointer<CChar>?
            let configureResult = sqlite3_exec(opened, sql, nil, nil, &errorMessage)
            guard configureResult == SQLITE_OK else {
                let message = errorMessage.map { String(cString: $0) }
                    ?? String(cString: sqlite3_errmsg(opened))
                if let errorMessage { sqlite3_free(errorMessage) }
                let error = DatabaseError.configure(
                    operation: operation, code: configureResult, message: message)
                AppLog.line(error.localizedDescription)
                sqlite3_close(opened)
                return nil
            }
        }
        db = opened
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Checked APIs

    /// Makes a consistent standalone snapshot, including committed WAL rows.
    /// The caller owns the new destination and any cleanup after an error.
    func backup(to destination: URL) throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw record(.backup(code: SQLITE_CANTOPEN, message: "backup destination already exists"))
        }
        var target: OpaquePointer?
        let openResult = sqlite3_open_v2(destination.path, &target,
                                        SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard openResult == SQLITE_OK, let target else {
            let detail = target.map { String(cString: sqlite3_errmsg($0)) }
                ?? String(cString: sqlite3_errstr(openResult))
            if let target { sqlite3_close(target) }
            throw record(.backup(code: openResult, message: detail))
        }
        defer { sqlite3_close(target) }
        guard let backup = sqlite3_backup_init(target, "main", db, "main") else {
            throw record(.backup(code: sqlite3_errcode(target), message: String(cString: sqlite3_errmsg(target))))
        }
        let stepResult = sqlite3_backup_step(backup, -1)
        let finishResult = sqlite3_backup_finish(backup)
        guard stepResult == SQLITE_DONE, finishResult == SQLITE_OK else {
            throw record(.backup(code: stepResult == SQLITE_DONE ? finishResult : stepResult,
                                 message: String(cString: sqlite3_errmsg(target))))
        }
        // A backup inherits WAL mode from the source header. Normalize it while
        // writable so a read-only verifier can open the standalone file without
        // requiring a new WAL/SHM pair in the recovery directory.
        let journalResult = sqlite3_exec(target, "PRAGMA journal_mode=DELETE", nil, nil, nil)
        guard journalResult == SQLITE_OK else {
            throw record(.backup(code: journalResult, message: String(cString: sqlite3_errmsg(target))))
        }
    }

    func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(db))
            if let errorMessage { sqlite3_free(errorMessage) }
            throw record(.execute(sql: sql, code: result, message: message))
        }
    }

    func runChecked(_ sql: String, bind values: [Any] = []) throws {
        try withPreparedStatement(sql, bind: values) { statement in
            try stepToCompletion(statement, sql: sql)
        }
    }

    /// Executes an already-prepared statement, resetting and rebinding it so
    /// callers can reuse one statement for a batch of rows.
    func runChecked(_ statement: OpaquePointer, bind values: [Any] = []) throws {
        let resetResult = sqlite3_reset(statement)
        guard resetResult == SQLITE_OK else {
            throw record(.reset(code: resetResult, message: message))
        }
        sqlite3_clear_bindings(statement)
        try bindChecked(values, to: statement)
        try stepToCompletion(statement, sql: nil)
    }

    /// Runs a group of writes atomically. Any thrown error rolls the whole
    /// group back before it is propagated to the caller.
    func withTransaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            do {
                try execute("ROLLBACK")
            } catch let rollbackError {
                AppLog.line("SQLite rollback also failed: \(rollbackError.localizedDescription)")
            }
            throw error
        }
    }

    func queryChecked<T>(_ sql: String, bind values: [Any] = [],
                         row: (OpaquePointer) -> T?) throws -> [T] {
        try withPreparedStatement(sql, bind: values) { statement in
            var rows: [T] = []
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                if let value = row(statement) {
                    rows.append(value)
                }
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else {
                throw record(.step(sql: sql, code: result, message: message))
            }
            return rows
        }
    }

    /// Stream rows without building an intermediate array. Returning `false`
    /// from `row` intentionally stops iteration (useful for bounded context
    /// assembly); SQLite failures encountered before that point still throw.
    func forEachRowChecked(_ sql: String, bind values: [Any] = [],
                           row: (OpaquePointer) -> Bool) throws {
        try withPreparedStatement(sql, bind: values) { statement in
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                guard row(statement) else { return }
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else {
                throw record(.step(sql: sql, code: result, message: message))
            }
        }
    }

    func firstDoubleChecked(_ sql: String, bind values: [Any] = []) throws -> Double? {
        try withPreparedStatement(sql, bind: values) { statement in
            let result = sqlite3_step(statement)
            switch result {
            case SQLITE_ROW:
                return sqlite3_column_double(statement, 0)
            case SQLITE_DONE:
                return nil
            default:
                throw record(.step(sql: sql, code: result, message: message))
            }
        }
    }

    func hasRowChecked(_ sql: String, bind values: [Any] = []) throws -> Bool {
        try withPreparedStatement(sql, bind: values) { statement in
            let result = sqlite3_step(statement)
            switch result {
            case SQLITE_ROW:
                return true
            case SQLITE_DONE:
                return false
            default:
                throw record(.step(sql: sql, code: result, message: message))
            }
        }
    }

    @discardableResult
    func withPreparedStatement<T>(_ sql: String, bind values: [Any] = [],
                                  _ body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw record(.prepare(sql: sql, code: result, message: message))
        }
        defer { sqlite3_finalize(statement) }
        try bindChecked(values, to: statement)
        return try body(statement)
    }

    // MARK: - Compatibility APIs

    @discardableResult
    func exec(_ sql: String) -> Bool {
        do {
            try execute(sql)
            return true
        } catch {
            return false
        }
    }

    /// Rowid of the most recent successful INSERT on this connection.
    func lastInsertRowID() -> Int64 {
        sqlite3_last_insert_rowid(db)
    }

    @discardableResult
    func run(_ sql: String, bind values: [Any] = []) -> Bool {
        do {
            try runChecked(sql, bind: values)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func run(_ statement: OpaquePointer, bind values: [Any] = []) -> Bool {
        do {
            try runChecked(statement, bind: values)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func transaction(_ body: () -> Bool) -> Bool {
        let generationAtStart = errorGeneration
        do {
            return try withTransaction {
                guard body() else {
                    if errorGeneration != generationAtStart, let lastError { throw lastError }
                    throw record(.step(
                        sql: nil, code: SQLITE_ABORT, message: "transaction body returned false")
                    )
                }
                return true
            }
        } catch {
            return false
        }
    }

    func query<T>(_ sql: String, bind values: [Any] = [], row: (OpaquePointer) -> T?) -> [T] {
        (try? queryChecked(sql, bind: values, row: row)) ?? []
    }

    func firstDouble(_ sql: String, bind values: [Any] = []) -> Double? {
        (try? firstDoubleChecked(sql, bind: values)) ?? nil
    }

    func hasRow(_ sql: String, bind values: [Any] = []) -> Bool {
        (try? hasRowChecked(sql, bind: values)) ?? false
    }

    @discardableResult
    func withStatement<T>(_ sql: String, bind values: [Any] = [],
                          _ body: (OpaquePointer) -> T) -> T? {
        try? withPreparedStatement(sql, bind: values, body)
    }

    // MARK: - Internals

    private var message: String { String(cString: sqlite3_errmsg(db)) }

    @discardableResult
    private func record(_ error: DatabaseError) -> DatabaseError {
        errorGeneration &+= 1
        lastError = error
        AppLog.line(error.localizedDescription)
        return error
    }

    private func stepToCompletion(_ statement: OpaquePointer, sql: String?) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            throw record(.step(sql: sql, code: result, message: message))
        }
    }

    private func bindChecked(_ values: [Any], to statement: OpaquePointer) throws {
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            let result: Int32
            switch value {
            case let text as String:
                result = sqlite3_bind_text(statement, position, text, -1, Self.transient)
            case let number as Double:
                result = sqlite3_bind_double(statement, position, number)
            case let number as Int:
                result = sqlite3_bind_int64(statement, position, sqlite3_int64(number))
            case let number as Int64:
                result = sqlite3_bind_int64(statement, position, sqlite3_int64(number))
            case let data as Data where data.isEmpty:
                result = sqlite3_bind_zeroblob(statement, position, 0)
            case let data as Data:
                result = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, position, bytes.baseAddress,
                                      Int32(data.count), Self.transient)
                }
            case is NSNull:
                result = sqlite3_bind_null(statement, position)
            default:
                let error = DatabaseError.bind(
                    index: position, code: SQLITE_MISMATCH,
                    message: "unsupported value type \(type(of: value))")
                assertionFailure(error.localizedDescription)
                throw record(error)
            }
            guard result == SQLITE_OK else {
                throw record(.bind(index: position, code: result, message: message))
            }
        }
    }
}
