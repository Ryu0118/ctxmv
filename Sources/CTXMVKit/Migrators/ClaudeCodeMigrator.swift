import Foundation

/// Writes unified conversations into Claude Code's JSONL format.
struct ClaudeCodeMigrator: SessionMigrator, Sendable {
    let target: AgentSource = .claudeCode

    private let fileSystem: any FileSystemProtocol
    private let projectPath: String?

    init(
        fileSystem: any FileSystemProtocol = DefaultFileSystem(),
        projectPath: String? = nil
    ) {
        self.fileSystem = fileSystem
        self.projectPath = projectPath
    }

    /// Writes the conversation into Claude Code's project-scoped session store.
    func migrate(_ conversation: UnifiedConversation) throws -> MigrationResult {
        guard !conversation.messages.isEmpty else {
            throw MigrationError.sessionEmpty
        }

        let projectDir = projectDirectory(for: conversation)
        let originDigest = MigrationDeduplicator.originDigest(for: conversation)
        let origin = MigrationOrigin(
            originId: conversation.id,
            originSource: conversation.source,
            originMessageCount: conversation.messages.count,
            originDigest: originDigest
        )

        if let existing = MigrationDeduplicator.findExistingMigration(
            origin: origin,
            in: projectDir,
            fileSystem: fileSystem,
            allowBareMetaLine: false
        ) {
            throw MigrationError.alreadyMigrated(existingPath: existing)
        }

        let sessionId = UUID().uuidString.lowercased()
        try fileSystem.createDirectory(at: projectDir, withIntermediateDirectories: true, attributes: nil)

        let fileURL = projectDir.appendingPathComponent("\(sessionId).jsonl")
        let jsonlContent = jsonl(for: conversation, sessionId: sessionId)

        guard let data = jsonlContent.data(using: .utf8) else {
            throw MigrationError.writeFailed("Failed to encode JSONL as UTF-8")
        }

        _ = fileSystem.createFile(atPath: fileURL.path, contents: data, attributes: nil)
        logger.info("💾 Wrote Claude Code session messages=\(conversation.messages.count) path=\(fileURL.path)")
        return .written(path: fileURL.path, sessionID: sessionId)
    }

    /// Resolves the `.claude/projects/<encoded-project>` directory for the session.
    func projectDirectory(for conversation: UnifiedConversation) -> URL {
        let cwd = projectPath ?? conversation.projectPath ?? FileManager.default.currentDirectoryPath
        let encoded = encodedProjectPath(for: cwd)
        return fileSystem.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
            .appendingPathComponent(encoded)
    }

    /// Claude Code encodes absolute paths by replacing `/` with `-`.
    func encodedProjectPath(for path: String) -> String {
        path.replacingOccurrences(of: "/", with: "-")
    }

    /// Builds the Claude Code JSONL payload, including the leading migration meta line.
    func jsonl(for conversation: UnifiedConversation, sessionId: String) -> String {
        var lines: [String] = []
        if let progressLine = migrationProgressMetaLine(for: conversation, sessionId: sessionId) {
            lines.append(progressLine)
        }
        lines.append(contentsOf: messageJSONLines(for: conversation, sessionId: sessionId))
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

    /// One JSONL object per user/assistant turn; `parentUuid` chains entries for ordering on resume.
    private func messageJSONLines(for conversation: UnifiedConversation, sessionId: String) -> [String] {
        let iso = MigratorUtils.isoFormatter
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
                message: ClaudeCodeMessage(role: encoding.messageRole, content: encoding.content)
            )
            if let line = MigratorUtils.encodeLine(entry) {
                lines.append(line)
            }
            parentUuid = uuid
        }
        return lines
    }
}

// Maps unified roles to Claude Code entry shape (plain string vs block array).
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
