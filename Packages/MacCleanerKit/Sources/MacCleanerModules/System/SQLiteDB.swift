import Foundation
import SQLite3

/// Minimal SQLite wrapper for counting and deleting browser data.
final class SQLiteDB {
    private var handle: OpaquePointer?
    /// False when the database could only be read as a frozen file (see `init`):
    /// the latest changes, still in the "-wal" file, are then missing.
    private(set) var readsLatest = true

    /// Opens read-write, or read-only.
    ///
    /// Read-only first tries a normal connection, which also sees the changes
    /// still in the "-wal" file. A running browser can keep its database locked;
    /// then the main file is read as it is ("immutable"), without the newest rows.
    init?(url: URL, readOnly: Bool) {
        guard readOnly else {
            guard let handle = Self.open(url.path, flags: SQLITE_OPEN_READWRITE, busyTimeout: 2000) else { return nil }
            self.handle = handle
            return
        }
        let encoded = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        if let handle = Self.open("file:\(encoded)?mode=ro", flags: flags, busyTimeout: 250) {
            self.handle = handle
        } else if let handle = Self.open("file:\(encoded)?mode=ro&immutable=1", flags: flags, busyTimeout: 0) {
            self.handle = handle
            readsLatest = false
        } else {
            return nil
        }
    }

    /// Opens a connection and makes sure the file can really be read.
    private static func open(_ path: String, flags: Int32, busyTimeout: Int32) -> OpaquePointer? {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        sqlite3_busy_timeout(handle, busyTimeout)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM sqlite_master", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else {
            sqlite3_finalize(statement)
            statement = nil
            sqlite3_close(handle)
            return nil
        }
        return handle
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

    /// Writes a complete, standalone copy of the database (latest changes
    /// included) to `destination`, which must not exist yet, and checks that
    /// the copy can be read back. Unlike copying the files, this never copies
    /// a symlink instead of the data.
    func snapshot(to destination: URL) -> Bool {
        guard readsLatest, !FileManager.default.fileExists(atPath: destination.path) else { return false }
        let quoted = destination.path.replacingOccurrences(of: "'", with: "''")
        guard execute("VACUUM INTO '\(quoted)'") else { return false }
        let values = try? destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values?.isRegularFile == true, values?.isSymbolicLink != true,
              let copy = SQLiteDB(url: destination, readOnly: true), copy.readsLatest else { return false }
        return copy.text("PRAGMA quick_check") == "ok"
    }

    /// The first column of the first row, as text.
    func text(_ sql: String) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: value)
    }

    func tableExists(_ name: String) -> Bool {
        count("sqlite_master", where: "type='table' AND name='\(name)'").map { $0 > 0 } ?? false
    }
}
