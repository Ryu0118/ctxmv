import CSQLite
import Foundation

/// Persists Cursor blob and metadata tables into `store.db`.
struct CursorStoreDatabaseWriter {
    /// Creates or updates Cursor's SQLite store with both blob rows and metadata rows.
    func writeStoreDatabase(
        at path: String,
        messageBlobs: [(idHex: String, data: Data)],
        metadataHex: String,
        migrationMetaJSON: String
    ) throws {
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK else {
            let message = database.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(database)
            throw MigrationError.writeFailed("Failed to open SQLite DB: \(message)")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 5000)

        try configure(database: database)
        try writeBlobs(messageBlobs, into: database)
        try writeMetadata(metadataHex: metadataHex, migrationMetaJSON: migrationMetaJSON, into: database)
    }

    /// Configures the SQLite file to match Cursor's expected schema and starts a transaction.
    private func configure(database: OpaquePointer?) throws {
        try execSQL(database, "PRAGMA journal_mode = WAL")
        try execSQL(database, "PRAGMA synchronous = NORMAL")
        try execSQL(database, "PRAGMA user_version = 1")
        try execSQL(database, "CREATE TABLE IF NOT EXISTS blobs (id TEXT PRIMARY KEY, data BLOB)")
        try execSQL(database, "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)")
        try execSQL(database, "BEGIN")
    }

    private func writeBlobs(
        _ messageBlobs: [(idHex: String, data: Data)],
        into database: OpaquePointer?
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "INSERT OR REPLACE INTO blobs (id, data) VALUES (?, ?)",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            throw MigrationError.writeFailed("Failed to prepare blobs insert statement")
        }
        defer { sqlite3_finalize(statement) }

        for blob in messageBlobs {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_text(statement, 1, blob.idHex, -1, sqliteTransientDestructor)
            _ = blob.data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(blob.data.count), sqliteTransientDestructor)
            }
            guard sqlite3_step(statement) == SQLITE_DONE else {
                let message = String(cString: sqlite3_errmsg(database))
                throw MigrationError.writeFailed("Failed to insert blob: \(message)")
            }
        }
    }

    private func writeMetadata(
        metadataHex: String,
        migrationMetaJSON: String,
        into database: OpaquePointer?
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            throw MigrationError.writeFailed("Failed to prepare meta insert statement")
        }
        defer { sqlite3_finalize(statement) }
        // Commit only after both metadata rows succeed so Cursor never sees a half-written session.
        defer { _ = sqlite3_exec(database, "COMMIT", nil, nil, nil) }

        try insertMeta("0", value: metadataHex, using: statement, database: database)
        try insertMeta(
            MigrationMeta.migrationType,
            value: migrationMetaJSON,
            using: statement,
            database: database
        )
    }

    private func insertMeta(
        _ key: String,
        value: String,
        using statement: OpaquePointer?,
        database: OpaquePointer?
    ) throws {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        sqlite3_bind_text(statement, 1, key, -1, sqliteTransientDestructor)
        sqlite3_bind_text(statement, 2, value, -1, sqliteTransientDestructor)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            let message = String(cString: sqlite3_errmsg(database))
            throw MigrationError.writeFailed("Failed to insert meta key '\(key)': \(message)")
        }
    }

    private func execSQL(_ database: OpaquePointer?, _ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw MigrationError.writeFailed("SQLite exec failed for '\(sql)': \(message)")
        }
    }
}

/// SQLite sentinel telling C to copy bound Swift buffers before this call returns.
let sqliteTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
