import Foundation
import Logging
import Rainbow

/// Finds a session, migrates it to a target agent format, and prints resume instructions.
package struct MigrateRunner {
    private let sessionID: String
    private let target: AgentSource
    private let source: AgentSource?

    private let readers: [any SessionReader]
    private let fileSystem: any FileSystemProtocol

    package init(
        sessionID: String,
        target: AgentSource,
        source: AgentSource? = nil,
        fileSystem: any FileSystemProtocol = DefaultFileSystem(),
        sqlite: any SQLiteReader = DefaultSQLiteReader()
    ) {
        self.sessionID = sessionID
        self.target = target
        self.source = source
        self.fileSystem = fileSystem
        readers = SessionReaderFactory.make(fileSystem: fileSystem, sqlite: sqlite)
    }

    /// Creates a runner with injected readers for tests.
    package init(
        sessionID: String,
        target: AgentSource,
        source: AgentSource? = nil,
        readers: [any SessionReader],
        fileSystem: any FileSystemProtocol = DefaultFileSystem()
    ) {
        self.sessionID = sessionID
        self.target = target
        self.source = source
        self.readers = readers
        self.fileSystem = fileSystem
    }

    package func run() async throws {
        let showRunner = ShowRunner(
            sessionID: sessionID,
            source: source,
            messageLimit: nil,
            largeSessionByteThreshold: nil,
            readers: readers
        )
        guard let conversation = try await showRunner.findSession() else {
            logger.error("Session '\(sessionID)' not found.")
            return
        }

        let migrator = buildMigrator()
        logger.info("🔄 Migrating session \(sessionID) to \(target.rawValue)...")

        do {
            let result = try migrator.migrate(conversation)
            switch result {
            case let .written(path, newSessionID):
                printResumeHint(
                    path: path,
                    sessionID: newSessionID,
                    projectPath: conversation.projectPath,
                    alreadyMigrated: false
                )
            }
        } catch let MigrationError.alreadyMigrated(existingPath) {
            let existingSessionID = extractSessionID(from: existingPath)
            printResumeHint(
                path: existingPath,
                sessionID: existingSessionID,
                projectPath: conversation.projectPath,
                alreadyMigrated: true
            )
        }
    }

    /// Selects the migrator matching the requested target agent.
    private func buildMigrator() -> any SessionMigrator {
        switch target {
        case .claudeCode: ClaudeCodeMigrator()
        case .codex: CodexMigrator()
        case .cursor: CursorMigrator()
        }
    }

    /// Prints the exact resume command, reusing the existing session path when migration was skipped as a duplicate.
    private func printResumeHint(path: String, sessionID: String, projectPath: String?, alreadyMigrated: Bool) {
        let resumeCommand = resumeCommand(forSessionID: sessionID)
        let resolvedProjectPath = resolveProjectPath(projectPath)
        let cwdForHint: String? = switch target {
        case .claudeCode:
            ClaudeResumeProjectPathResolver.cdPath(
                forStoredProjectPath: resolvedProjectPath,
                writtenJSONLPath: path,
                fileSystem: fileSystem
            )
        case .codex, .cursor:
            resolvedProjectPath
        }
        let cwdLine = cwdForHint.map { "  cd \($0)\n" } ?? ""
        let claudeCwdNote = """
        ⚠️ Claude Code resolves sessions by current working directory (~/.claude/projects/<encoded cwd>/).
           Running `claude` from a different project folder will not find this session.

        """

        if alreadyMigrated {
            logger.warning("""
            ⚠️ Already migrated to: \(path)
            \(target == .claudeCode ? claudeCwdNote : "")
            To resume:
            \(cwdLine)  \(resumeCommand)
            """, metadata: .color(.yellow))
        } else {
            logger.info("""
            ✅ Session written to: \(path)
            \(target == .claudeCode ? claudeCwdNote : "")
            To resume:
            \(cwdLine)  \(resumeCommand)
            """, metadata: .color(.green))
        }

        if target == .cursor {
            logger.warning("""
            ⚠️ Note: Cursor may not render migrated past messages in TUI immediately after resume.
            However, conversation context is preserved and past messages are still available to the agent.
            """, metadata: .color(.yellow))
        }
    }

    private func resumeCommand(forSessionID sessionID: String) -> String {
        switch target {
        case .claudeCode: "claude --resume \(sessionID)"
        case .codex: "codex resume \(sessionID)"
        case .cursor: "cursor-agent --resume \(sessionID)"
        }
    }

    /// If the stored project path doesn't exist on disk, tries to find the real directory
    /// by re-encoding and searching for candidates (handles Claude Code's lossy `-` encoding).
    private func resolveProjectPath(_ projectPath: String?) -> String? {
        guard let projectPath, !projectPath.isEmpty else { return nil }
        var isDirectory = ObjCBool(false)
        if fileSystem.fileExists(atPath: projectPath, isDirectory: &isDirectory), isDirectory.boolValue {
            return projectPath
        }
        let encoded = MigratorUtils.encodedClaudeProjectPath(projectPath)
        let candidates = ClaudeResumeProjectPathResolver.existingDirectoryCandidates(
            encoded: encoded,
            fileSystem: fileSystem
        )
        return candidates.first ?? projectPath
    }

    /// Derives the resumable session ID from the storage path format of each target agent.
    private func extractSessionID(from path: String) -> String {
        let fileName = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        switch target {
        case .claudeCode:
            return fileName
        case .codex:
            // Codex rollout files are `rollout-YYYY-MM-DDTHH-MM-SS-<uuid>.jsonl`.
            let parts = fileName.components(separatedBy: "-")
            return parts.count >= 5 ? parts.suffix(5).joined(separator: "-") : fileName
        case .cursor:
            return fileName == "store"
                ? URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
                : fileName
        }
    }
}
