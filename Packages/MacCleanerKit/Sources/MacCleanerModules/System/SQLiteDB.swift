import Foundation
import SQLite3

/// Minimal SQLite wrapper for counting and deleting browser data.
final class SQLiteDB {
    private var handle: OpaquePointer?

    /// Opens read-only and immutable (safe while the browser is running) or read-write.
    init?(url: URL, readOnly: Bool) {
        let path = readOnly
            ? "file:\(url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path)?mode=ro&immutable=1"
            : url.path
        let flags = readOnly ? (SQLITE_OPEN_READONLY | SQLITE_OPEN_URI) : SQLITE_OPEN_READWRITE
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        sqlite3_busy_timeout(handle, 2000)
    }

    deinit { sqlite3_close(handle) }

    func count(_ table: String, where clause: String? = nil) -> Int? {
        let sql = "SELECT COUNT(*) FROM \(table)" + (clause.map { " WHERE \($0)" } ?? "")
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(statement, 0))
    }

    @discardableResult
    func execute(_ sql: String) -> Bool {
        sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK
    }

    func tableExists(_ name: String) -> Bool {
        count("sqlite_master", where: "type='table' AND name='\(name)'").map { $0 > 0 } ?? false
    }
}
