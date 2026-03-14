import Foundation
import Logging
import Rainbow

/// Finds a session, migrates it to a target agent format, and prints resume instructions.
package struct MigrateRunner: Sendable {
    private let sessionID: String
    private let target: AgentSource

    private let readers: [SessionReader]

    package init(
        sessionID: String,
        target: AgentSource,
        fileSystem: FileSystemProtocol = DefaultFileSystem(),
        sqlite: SQLiteReader = DefaultSQLiteReader()
    ) {
        self.sessionID = sessionID
        self.target = target
        readers = SessionReaderFactory.make(fileSystem: fileSystem, sqlite: sqlite)
    }

    /// Creates a runner with injected readers for tests.
    package init(
        sessionID: String,
        target: AgentSource,
        readers: [SessionReader]
    ) {
        self.sessionID = sessionID
        self.target = target
        self.readers = readers
    }

    package func run() async throws {
        let showRunner = ShowRunner(
            sessionID: sessionID,
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
    private func buildMigrator() -> SessionMigrator {
        switch target {
        case .claudeCode: ClaudeCodeMigrator()
        case .codex: CodexMigrator()
        case .cursor: CursorMigrator()
        }
    }

    /// Prints the exact resume command, reusing the existing session path when migration was skipped as a duplicate.
    private func printResumeHint(path: String, sessionID: String, projectPath: String?, alreadyMigrated: Bool) {
        let resumeCommand = resumeCommand(forSessionID: sessionID)
        let cwdLine = projectPath.map { "  cd \($0)\n" } ?? ""

        if alreadyMigrated {
            logger.warning("""
            ⚠️ Already migrated to: \(path)

            To resume:
            \(cwdLine)  \(resumeCommand)
            """, metadata: .color(.yellow))
        } else {
            logger.info("""
            ✅ Session written to: \(path)

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
