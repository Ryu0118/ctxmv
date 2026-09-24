import Foundation
import Logging
import Rainbow

/// Finds a session, migrates it to a target agent format, and prints resume instructions.
package struct MigrateRunner {
    private let sessionID: String
    private let target: MigrationTarget
    private let source: AgentSource?

    private let readers: [any SessionReader]
    private let fileSystem: any FileSystemProtocol
    private let copilotSessionImporter: any CopilotSessionImporter
    private let copilotHome: URL?

    /// Creates a runner using the default file system and SQLite provider.
    package init(
        sessionID: String,
        target: MigrationTarget,
        source: AgentSource? = nil,
        fileSystem: any FileSystemProtocol = DefaultFileSystem(),
        sqlite: any SQLiteReader = DefaultSQLiteReader(),
        copilotSessionImporter: any CopilotSessionImporter = CopilotCommandSessionImporter(),
        copilotHome: URL? = nil
    ) {
        self.sessionID = sessionID
        self.target = target
        self.source = source
        self.fileSystem = fileSystem
        self.copilotSessionImporter = copilotSessionImporter
        self.copilotHome = Self.configuredCopilotHome(explicit: copilotHome)
        readers = SessionReaderFactory.make(fileSystem: fileSystem, sqlite: sqlite)
    }

    /// Creates a runner with injected readers for tests.
    package init(
        sessionID: String,
        target: MigrationTarget,
        source: AgentSource? = nil,
        readers: [any SessionReader],
        fileSystem: any FileSystemProtocol = DefaultFileSystem(),
        copilotSessionImporter: any CopilotSessionImporter = CopilotCommandSessionImporter(),
        copilotHome: URL? = nil
    ) {
        self.sessionID = sessionID
        self.target = target
        self.source = source
        self.readers = readers
        self.fileSystem = fileSystem
        self.copilotSessionImporter = copilotSessionImporter
        self.copilotHome = Self.configuredCopilotHome(explicit: copilotHome)
    }

    /// Locates the session, migrates it to the target format, and prints resume instructions.
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
        // `PWD` is the shell's logical cwd (symlinks preserved); reading it here keeps env access
        // at the CLI boundary rather than inside the migrator. See ``ClaudeProjectAliasResolver``.
        case .claudeCode: ClaudeCodeMigrator(
                fileSystem: fileSystem,
                logicalCwd: ProcessInfo.processInfo.environment["PWD"]
            )
        case .codex: CodexMigrator(fileSystem: fileSystem)
        case .cursor: CursorMigrator(fileSystem: fileSystem)
        // Same `PWD` rationale as above: kimi's workspace id hashes the root path.
        case .kimiCode: KimiCodeMigrator(
                fileSystem: fileSystem,
                workingDirectoryProvider: Self.logicalWorkingDirectory
            )
        case .copilotCLI: CopilotCLIMigrator(
                fileSystem: fileSystem,
                copilotHome: copilotHome ?? fileSystem.homeDirectoryForCurrentUser.appendingPathComponent(".copilot"),
                importer: copilotSessionImporter
            )
        }
    }

    private static func configuredCopilotHome(explicit: URL?) -> URL? {
        if let explicit { return explicit }
        guard let configured = ProcessInfo.processInfo.environment["COPILOT_HOME"], !configured.isEmpty else {
            return nil
        }
        return URL(filePath: configured)
    }

    /// The shell's logical cwd (symlinks preserved), falling back to the physical one.
    private static func logicalWorkingDirectory() -> String {
        ProcessInfo.processInfo.environment["PWD"] ?? FileManager.default.currentDirectoryPath
    }

    /// Prints the exact resume command, reusing the existing session path when migration was skipped as a duplicate.
    private func printResumeHint(path: String, sessionID: String, projectPath: String?, alreadyMigrated: Bool) {
        let resumeCommand = resumeCommand(forSessionID: sessionID)
        let resolvedProjectPath = ProjectPathResolver.resolveProjectPath(projectPath, fileSystem: fileSystem)
        let cwdForHint: String? = switch target {
        case .claudeCode:
            ProjectPathResolver.cdPath(
                forStoredProjectPath: resolvedProjectPath,
                writtenJSONLPath: path,
                fileSystem: fileSystem
            )
        case .codex, .cursor, .kimiCode, .copilotCLI:
            resolvedProjectPath
        }
        let cwdLine = cwdForHint.map { "  cd -- \(Self.shellQuoted($0))\n" } ?? ""
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
        case .kimiCode: "kimi --session \(sessionID)"
        case .copilotCLI: "copilot --resume=\(sessionID)"
        }
    }

    /// Quotes one argument for the shell command hints printed by the CLI.
    package static func shellQuoted(_ argument: String) -> String {
        "'\(argument.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    /// Derives the resumable session ID from the storage path format of each target agent.
    private func extractSessionID(from path: String) -> String {
        let fileName = URL(filePath: path).deletingPathExtension().lastPathComponent
        switch target {
        case .claudeCode:
            return fileName
        case .codex:
            // Codex rollout files are `rollout-YYYY-MM-DDTHH-MM-SS-<uuid>.jsonl`.
            let parts = fileName.components(separatedBy: "-")
            return parts.count >= 5 ? parts.suffix(5).joined(separator: "-") : fileName
        case .cursor:
            return fileName == "store"
                ? URL(filePath: path).deletingLastPathComponent().lastPathComponent
                : fileName
        case .kimiCode, .copilotCLI:
            // Both importers return their session directory; its last component is the resumable id.
            return fileName
        }
    }
}
