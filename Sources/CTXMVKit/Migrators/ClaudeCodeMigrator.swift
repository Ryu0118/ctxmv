import Foundation

/// Writes unified conversations into Claude Code's JSONL format.
struct ClaudeCodeMigrator: SessionMigrator {
    let target: AgentSource = .claudeCode

    private let fileSystem: any FileSystemProtocol
    private let projectPath: String?
    /// The shell's logical working directory (`PWD`), read at the CLI boundary. When it is a symlink
    /// alias of the resolved project path, the session is also written to its bucket. See ``migrate(_:)``.
    private let logicalCwd: String?

    init(
        fileSystem: any FileSystemProtocol = DefaultFileSystem(),
        projectPath: String? = nil,
        logicalCwd: String? = nil
    ) {
        self.fileSystem = fileSystem
        self.projectPath = projectPath
        self.logicalCwd = logicalCwd
    }

    /// Writes the conversation into Claude Code's project-scoped session store.
    ///
    /// When the project path is reachable through a symlink alias (e.g. `~/work -> /Volumes/Disk/work`),
    /// the session is written to *both* aliased project buckets. Claude Code resolves `--resume` against
    /// the current working directory, so this lets resume succeed whether the user `cd`s into the logical
    /// or the physical path. See ``ClaudeProjectAliasResolver``.
    func migrate(_ conversation: UnifiedConversation) throws -> MigrationResult {
        guard !conversation.messages.isEmpty else {
            throw MigrationError.sessionEmpty
        }
        let cwd = resolvedCwd(for: conversation)
        let projectDirs = projectDirectories(forCwd: cwd)
        guard let primaryDir = projectDirs.first else {
            throw MigrationError.writeFailed("No Claude Code project directory resolved")
        }
        let origin = migrationOrigin(for: conversation)

        // Dedup across every bucket so a re-migration does not write into one alias while
        // throwing on another. Note: a session migrated before this multi-bucket behavior existed
        // lives only in the physical bucket; re-running migration finds it there and throws
        // `alreadyMigrated` without backfilling the logical bucket. That is intentional (dedup is
        // keyed on the unchanged source session); such sessions resume from the physical cwd only.
        for dir in projectDirs {
            if let existing = MigrationDeduplicator.findExistingMigration(
                origin: origin,
                in: dir,
                fileSystem: fileSystem,
                allowBareMetaLine: false
            ) {
                throw MigrationError.alreadyMigrated(existingPath: existing)
            }
        }

        let sessionId = UUID().uuidString.lowercased()
        guard let data = jsonl(for: conversation, sessionId: sessionId, cwd: cwd).data(using: .utf8) else {
            throw MigrationError.writeFailed("Failed to encode JSONL as UTF-8")
        }

        for dir in projectDirs {
            try fileSystem.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
            let fileURL = dir.appendingPathComponent("\(sessionId).jsonl")
            _ = fileSystem.createFile(atPath: fileURL.path, contents: data, attributes: nil)
            logger.info("💾 Wrote Claude Code session messages=\(conversation.messages.count) path=\(fileURL.path)")
        }

        let primaryPath = primaryDir.appendingPathComponent("\(sessionId).jsonl").path
        return .written(path: primaryPath, sessionID: sessionId)
    }

    /// The resolved physical working directory the session belongs to.
    private func resolvedCwd(for conversation: UnifiedConversation) -> String {
        projectPath ?? conversation.projectPath ?? FileManager.default.currentDirectoryPath
    }

    /// Resolves the project bucket(s) to write the session into: the physical bucket, plus the
    /// symlink-aliased logical bucket when `logicalCwd` is an alias of `cwd`.
    func projectDirectories(forCwd cwd: String) -> [URL] {
        let alias = ClaudeProjectAliasResolver.alias(forPhysicalPath: cwd, logicalCwd: logicalCwd)
        return ([cwd] + (alias.map { [$0] } ?? [])).map(projectDirectory(forPath:))
    }

    /// Maps an absolute project path to its `.claude/projects/<encoded>` directory.
    private func projectDirectory(forPath path: String) -> URL {
        fileSystem.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
            .appendingPathComponent(encodedProjectPath(for: path))
    }

    /// Claude Code encodes absolute paths by replacing `/` with `-`.
    func encodedProjectPath(for path: String) -> String {
        MigratorUtils.encodedClaudeProjectPath(path)
    }

    /// Builds the Claude Code JSONL payload.
    ///
    /// The `ctxmv_migration` meta is written as a trailing `progress` line, not a leading one:
    /// the current Claude Code TUI rejects a session whose first line is `progress` ("Failed to
    /// resume"), but tolerates one at the end. Dedup reads the whole file, so trailing is safe.
    /// The first line is therefore the first conversation entry, matching a real session.
    func jsonl(for conversation: UnifiedConversation, sessionId: String, cwd: String) -> String {
        var lines = messageJSONLines(for: conversation, sessionId: sessionId, cwd: cwd)
        if let progressLine = migrationProgressMetaLine(for: conversation, sessionId: sessionId) {
            lines.append(progressLine)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `progress` line wrapping `ctxmv_migration` so Claude Code recognizes the session (resume contract).
    private func migrationProgressMetaLine(for conversation: UnifiedConversation, sessionId: String) -> String? {
        let origin = migrationOrigin(for: conversation)
        let createdAt = MigratorUtils.isoFormatter.string(from: conversation.createdAt)
        return MigrationDeduplicator.encodeClaudeCodeMeta(
            origin: origin,
            sessionId: sessionId,
            timestamp: createdAt
        )
    }

    private func migrationOrigin(for conversation: UnifiedConversation) -> MigrationOrigin {
        MigrationOrigin(
            originId: conversation.id,
            originSource: conversation.source,
            originMessageCount: conversation.messages.count,
            originDigest: MigrationDeduplicator.originDigest(for: conversation)
        )
    }

    /// One JSONL object per user/assistant turn.
    ///
    /// Each entry carries the metadata the Claude Code TUI requires to resume a session:
    /// `cwd`/`version`/`gitBranch`/`isSidechain` and a `parentUuid` chain (`null` on the first
    /// entry). Assistant messages additionally carry `message.model`. These fields were empirically
    /// confirmed necessary — without them resume fails with "Failed to resume".
    private func messageJSONLines(for conversation: UnifiedConversation, sessionId: String, cwd: String) -> [String] {
        let iso = MigratorUtils.isoFormatter
        // Resume requires a non-empty model on assistant messages; any value satisfies it, so fall
        // back to a sentinel when the source conversation has none (e.g. Codex rollouts).
        let model = conversation.model.flatMap { $0.isEmpty ? nil : $0 } ?? Self.unknownModel
        var parentUuid: String?
        var lines: [String] = []
        for message in conversation.messages {
            let body = message.decodedContent(for: conversation.source)
            guard let encoding = ClaudeCodeMessageEncoding(message: message, body: body) else { continue }

            let uuid = UUID().uuidString.lowercased()
            let timestamp = iso.string(from: message.timestamp ?? Date())
            let entry = ClaudeCodeEntry(
                type: encoding.entryType,
                sessionId: sessionId,
                timestamp: timestamp,
                uuid: uuid,
                parentUuid: parentUuid,
                version: Self.resumeContractVersion,
                cwd: cwd,
                gitBranch: "",
                message: ClaudeCodeMessage(
                    role: encoding.messageRole,
                    content: encoding.content,
                    model: encoding.entryType == ClaudeCodeEntryType.assistant.rawValue ? model : nil
                ),
                isSidechain: false
            )
            if let line = MigratorUtils.encodeLine(entry) {
                lines.append(line)
            }
            parentUuid = uuid
        }
        return lines
    }

    /// Placeholder `version` written into migrated entries. Any non-empty value satisfies the resume
    /// contract; a fixed sentinel avoids implying a specific Claude Code build produced the session.
    private static let resumeContractVersion = "0.0.0"

    /// Fallback `message.model` when the source conversation records none.
    private static let unknownModel = "unknown"
}

/// Maps unified roles to Claude Code entry shape (plain string vs block array).
private struct ClaudeCodeMessageEncoding {
    let entryType: String
    let messageRole: String
    let content: TextOrBlocks

    init?(message: UnifiedMessage, body: String) {
        switch message.role {
        case .user:
            entryType = ClaudeCodeEntryType.user.rawValue
            messageRole = ClaudeCodeMessageRole.user.rawValue
            content = .text(body)
        case .assistant:
            entryType = ClaudeCodeEntryType.assistant.rawValue
            messageRole = ClaudeCodeMessageRole.assistant.rawValue
            content = .blocks([ContentBlock(type: .text, text: body)])
        default:
            return nil
        }
    }
}
