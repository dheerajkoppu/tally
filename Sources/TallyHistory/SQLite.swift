import Foundation
import SQLite3

private let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One SQLite connection with a cache of prepared statements. Not thread-safe: use it from one serial queue.
final class SQLiteConnection {
    private var handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]

    init?(path: String) {
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &opened, flags, nil) == SQLITE_OK, let opened else {
            if let opened { sqlite3_close_v2(opened) }
            return nil
        }
        handle = opened
        sqlite3_busy_timeout(opened, 2000)
        sqlite3_extended_result_codes(opened, 1)
    }

    deinit {
        close()
    }

    func close() {
        for statement in statements.values { sqlite3_finalize(statement) }
        statements.removeAll()
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    var errorMessage: String {
        guard let handle, let message = sqlite3_errmsg(handle) else { return "no connection" }
        return String(cString: message)
    }

    /// The primary result code of the last failed call, e.g. SQLITE_CORRUPT.
    var primaryErrorCode: Int32 {
        guard let handle else { return SQLITE_CANTOPEN }
        return sqlite3_errcode(handle) & 0xFF
    }

    @discardableResult
    func execute(_ sql: String) -> Bool {
        sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK
    }

    /// A cached prepared statement, reset and with its bindings cleared.
    func prepared(_ sql: String) -> SQLiteStatement? {
        if let cached = statements[sql] {
            sqlite3_reset(cached)
            sqlite3_clear_bindings(cached)
            return SQLiteStatement(pointer: cached)
        }
        var pointer: OpaquePointer?
        guard sqlite3_prepare_v3(handle, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &pointer, nil) == SQLITE_OK, let pointer else {
            if let pointer { sqlite3_finalize(pointer) }
            return nil
        }
        statements[sql] = pointer
        return SQLiteStatement(pointer: pointer)
    }

    /// The first column of the first row, for PRAGMA reads and single aggregates.
    func scalar(_ sql: String) -> Int64? {
        guard let statement = prepared(sql) else { return nil }
        defer { statement.reset() }
        guard statement.step() == SQLITE_ROW, !statement.isNull(at: 0) else { return nil }
        return statement.int64(at: 0)
    }
}

struct SQLiteStatement {
    let pointer: OpaquePointer

    func bind(_ value: Double?, at index: Int32) {
        if let value, value.isFinite {
            sqlite3_bind_double(pointer, index, value)
        } else {
            sqlite3_bind_null(pointer, index)
        }
    }

    func bind(_ value: Int64, at index: Int32) {
        sqlite3_bind_int64(pointer, index, value)
    }

    func bind(_ value: String?, at index: Int32) {
        if let value {
            sqlite3_bind_text(pointer, index, value, -1, transientDestructor)
        } else {
            sqlite3_bind_null(pointer, index)
        }
    }

    func step() -> Int32 {
        sqlite3_step(pointer)
    }

    func reset() {
        sqlite3_reset(pointer)
    }

    /// Runs a statement that returns no rows (or one row that is ignored).
    @discardableResult
    func run() -> Bool {
        let code = step()
        reset()
        return code == SQLITE_DONE || code == SQLITE_ROW
    }

    /// Calls `body` for every row, then resets so the statement does not hold a read snapshot open.
    @discardableResult
    func forEachRow(_ body: () -> Void) -> Bool {
        var code = step()
        while code == SQLITE_ROW {
            body()
            code = step()
        }
        reset()
        return code == SQLITE_DONE
    }

    func isNull(at column: Int32) -> Bool {
        sqlite3_column_type(pointer, column) == SQLITE_NULL
    }

    func double(at column: Int32) -> Double {
        sqlite3_column_double(pointer, column)
    }

    func int64(at column: Int32) -> Int64 {
        sqlite3_column_int64(pointer, column)
    }

    func string(at column: Int32) -> String? {
        guard let text = sqlite3_column_text(pointer, column) else { return nil }
        return String(cString: text)
    }
}
