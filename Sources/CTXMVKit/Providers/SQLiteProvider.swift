import CSQLite
import Foundation

/// Abstraction for SQLite access, enabling testability via mock implementations
package protocol SQLiteProvider: Sendable {
    func query(dbPath: String, sql: String) throws -> [[String: Any]]
    func queryBlobs(dbPath: String) throws -> [(id: String, data: Data)]
    func queryRecentBlobs(dbPath: String, limit: Int) throws -> [(id: String, data: Data)]
}

/// Describes SQLite query failures in provider implementations.
enum SQLiteError: Error {
    case cannotOpen(String)
    case queryFailed(String)
}

/// Reads Cursor SQLite stores through the system SQLite library.
package struct DefaultSQLiteProvider: SQLiteProvider, Sendable {
    package init() {}

    package func query(dbPath: String, sql: String) throws -> [[String: Any]] {
        try withPreparedStatement(dbPath: dbPath, sql: sql) { stmt, columnCount in
            var results: [[String: Any]] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                var row: [String: Any] = [:]
                for i in 0 ..< columnCount {
                    let name = String(cString: sqlite3_column_name(stmt, i))
                    switch sqlite3_column_type(stmt, i) {
                    case SQLITE_INTEGER:
                        row[name] = sqlite3_column_int64(stmt, i)
                    case SQLITE_FLOAT:
                        row[name] = sqlite3_column_double(stmt, i)
                    case SQLITE_TEXT:
                        row[name] = String(cString: sqlite3_column_text(stmt, i))
                    case SQLITE_BLOB:
                        let bytes = sqlite3_column_bytes(stmt, i)
                        if let ptr = sqlite3_column_blob(stmt, i) {
                            row[name] = Data(bytes: ptr, count: Int(bytes))
                        }
                    default:
                        row[name] = NSNull()
                    }
                }
                results.append(row)
            }
            return results
        }
    }

    package func queryBlobs(dbPath: String) throws -> [(id: String, data: Data)] {
        try withPreparedStatement(dbPath: dbPath, sql: "SELECT id, data FROM blobs") { statement, _ in
            var results: [(id: String, data: Data)] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let blobId = String(cString: sqlite3_column_text(statement, 0))
                let bytes = sqlite3_column_bytes(statement, 1)
                if let pointer = sqlite3_column_blob(statement, 1) {
                    results.append((id: blobId, data: Data(bytes: pointer, count: Int(bytes))))
                }
            }
            return results
        }
    }

    package func queryRecentBlobs(dbPath: String, limit: Int) throws -> [(id: String, data: Data)] {
        let safeLimit = max(1, limit)
        let sql = """
        SELECT id, data FROM (
            SELECT rowid, id, data
            FROM blobs
            ORDER BY rowid DESC
            LIMIT \(safeLimit)
        )
        ORDER BY rowid ASC
        """

        return try withPreparedStatement(dbPath: dbPath, sql: sql) { statement, _ in
            var results: [(id: String, data: Data)] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let blobId = String(cString: sqlite3_column_text(statement, 0))
                let bytes = sqlite3_column_bytes(statement, 1)
                if let pointer = sqlite3_column_blob(statement, 1) {
                    results.append((id: blobId, data: Data(bytes: pointer, count: Int(bytes))))
                }
            }
            return results
        }
    }

    private func withPreparedStatement<T>(
        dbPath: String,
        sql: String,
        body: (OpaquePointer, Int32) throws -> T
    ) throws -> T {
        var databaseConnection: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &databaseConnection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let message = databaseConnection.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(databaseConnection)
            throw SQLiteError.cannotOpen(message)
        }
        defer { sqlite3_close(databaseConnection) }
        sqlite3_busy_timeout(databaseConnection, 5000)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(databaseConnection, sql, -1, &statement, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(databaseConnection))
            throw SQLiteError.queryFailed(message)
        }
        defer { sqlite3_finalize(statement) }

        let columnCount = sqlite3_column_count(statement)
        return try body(statement!, columnCount)
    }
}
