import CSQLite
import Foundation

/// Finds prior Cursor migrations for strict deduplication.
struct CursorMigrationScanner {
    private let fileSystem: any FileSystemProtocol
    private let targetFormatVersion: Int

    init(fileSystem: any FileSystemProtocol, targetFormatVersion: Int) {
        self.fileSystem = fileSystem
        self.targetFormatVersion = targetFormatVersion
    }

    /// Scans Cursor workspace session directories for a prior migration of the same source snapshot.
    func findExistingMigration(
        originId: String,
        originSource: AgentSource,
        originMessageCount: Int,
        originDigest: String,
        in chatsWorkspaceDirectory: URL
    ) -> String? {
        guard fileSystem.fileExists(atPath: chatsWorkspaceDirectory.path),
              let sessionDirectories = try? fileSystem.contentsOfDirectory(
                  at: chatsWorkspaceDirectory,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles]
              )
        else {
            return nil
        }

        for sessionDirectory in sessionDirectories {
            let databasePath = sessionDirectory.appendingPathComponent("store.db").path
            guard fileSystem.fileExists(atPath: databasePath),
                  let metadata = readMigrationMeta(fromStoreDB: databasePath)
            else {
                continue
            }

            guard metadata.originId == originId,
                  metadata.originSource == originSource.rawValue
            else {
                continue
            }

            // Allow one-time re-migration for old format versions.
            if (metadata.targetFormatVersion ?? 0) < targetFormatVersion {
                continue
            }

            if let existingDigest = metadata.originDigest {
                if existingDigest == originDigest {
                    return databasePath
                }
                continue
            }

            if metadata.originMessageCount == originMessageCount {
                return databasePath
            }
        }

        return nil
    }

    private func readMigrationMeta(fromStoreDB path: String) -> MigrationMeta? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(database)
            return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 5000)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT value FROM meta WHERE key = ? LIMIT 1",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }

        // Cursor stores migration bookkeeping in the `meta` table using the migration type as the key.
        sqlite3_bind_text(statement, 1, MigrationMeta.migrationType, -1, sqliteTransientDestructor)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let pointer = sqlite3_column_text(statement, 0)
        else {
            return nil
        }

        let json = String(cString: pointer)
        guard let data = json.data(using: .utf8),
              let metadata = try? JSONDecoder().decode(MigrationMeta.self, from: data),
              // Ignore entries written by older migration formats so callers can upgrade once.
              metadata.type == MigrationMeta.migrationType
        else {
            return nil
        }

        return metadata
    }
}
