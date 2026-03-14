import Foundation
#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif

/// Groups the destination paths required for a Cursor migration.
struct CursorMigrationPaths: Sendable {
    let projectPath: String
    let chatsWorkspaceDirectory: URL
    let transcriptFile: URL
}

/// Resolves Cursor-native storage locations from a conversation and project path.
struct CursorMigrationPathResolver: Sendable {
    private let projectPathOverride: String?
    private let homeDirectory: URL

    init(projectPath: String?, homeDirectory: URL) {
        projectPathOverride = projectPath
        self.homeDirectory = homeDirectory
    }

    func projectPath(for conversation: UnifiedConversation) -> String {
        projectPathOverride
            ?? conversation.projectPath
            ?? FileManager.default.currentDirectoryPath
    }

    /// Cursor transcript storage uses slash-to-dash workspace encoding under `.cursor/projects`.
    func transcriptFile(for projectPath: String, sessionId: String) -> URL {
        let encodedWorkspace = projectPath
            .split(separator: "/")
            .joined(separator: "-")

        return homeDirectory
            .appendingPathComponent(".cursor/projects")
            .appendingPathComponent(encodedWorkspace, isDirectory: true)
            .appendingPathComponent("agent-transcripts", isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl")
    }

    /// Cursor chat storage uses an MD5 of the project path for workspace bucketing.
    func chatsWorkspaceDirectory(for projectPath: String) -> URL {
        let digest = Insecure.MD5.hash(data: Data(projectPath.utf8))
        let workspaceHash = MigratorUtils.hexString(Data(digest))

        return homeDirectory
            .appendingPathComponent(".cursor/chats")
            .appendingPathComponent(workspaceHash, isDirectory: true)
    }
}
