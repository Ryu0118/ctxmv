import Foundation

/// Centralized factory for session providers used across runners.
enum SessionProviderFactory {
    static func make(
        fileSystem: FileSystemProtocol = DefaultFileSystem(),
        sqlite: SQLiteProvider = DefaultSQLiteProvider()
    ) -> [SessionProvider] {
        [
            ClaudeCodeProvider(fileSystem: fileSystem),
            CodexProvider(fileSystem: fileSystem),
            CursorProvider(fileSystem: fileSystem, sqlite: sqlite),
        ]
    }
}
