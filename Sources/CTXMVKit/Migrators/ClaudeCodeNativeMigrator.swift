import Foundation

/// Writes unified conversations into Claude Code's native JSONL format.
struct ClaudeCodeNativeMigrator: SessionMigrator, Sendable {
    let target: AgentSource = .claudeCode

    private let fileSystem: FileSystemProtocol
    private let projectPath: String?

    init(
        fileSystem: FileSystemProtocol = DefaultFileSystem(),
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

        if let existing = MigrationDeduplicator.findExistingMigration(
            originId: conversation.id,
            originSource: conversation.source,
            originMessageCount: conversation.messages.count,
            originDigest: originDigest,
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
        logger.info("💾 Wrote native Claude Code session messages=\(conversation.messages.count) path=\(fileURL.path)")
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
        let formatter = MigratorUtils.isoFormatter
        let originDigest = MigrationDeduplicator.originDigest(for: conversation)

        var lines: [String] = []

        if let metaLine = MigrationDeduplicator.encodeClaudeCodeMeta(
            originId: conversation.id,
            originSource: conversation.source,
            originMessageCount: conversation.messages.count,
            originDigest: originDigest,
            sessionId: sessionId,
            timestamp: formatter.string(from: conversation.createdAt)
        ) {
            lines.append(metaLine)
        }

        var parentUuid: String? = nil

        for message in conversation.messages {
            guard message.role == .user || message.role == .assistant else { continue }

            let uuid = UUID().uuidString.lowercased()
            let timestamp = formatter.string(from: message.timestamp ?? Date())
            let body = message.decodedContent(for: conversation.source)

            let content: TextOrBlocks
            let messageRole: String
            let entryType: String
            if message.role == .user {
                // Claude Code stores user content as a plain string.
                content = .text(body)
                messageRole = ClaudeCodeMessageRole.user.rawValue
                entryType = ClaudeCodeEntryType.user.rawValue
            } else {
                // Assistant content uses block arrays so tool uses and rich output can coexist.
                content = .blocks([ContentBlock(type: .text, text: body)])
                messageRole = ClaudeCodeMessageRole.assistant.rawValue
                entryType = ClaudeCodeEntryType.assistant.rawValue
            }

            let entry = ClaudeCodeEntry(
                type: entryType,
                sessionId: sessionId,
                timestamp: timestamp,
                uuid: uuid,
                parentUuid: parentUuid,
                message: ClaudeCodeMessage(role: messageRole, content: content)
            )

            if let jsonStr = MigratorUtils.encodeLine(entry) {
                lines.append(jsonStr)
            }

            // Claude Code threads entries through parent UUIDs so resume can reconstruct order.
            parentUuid = uuid
        }

        return lines.joined(separator: "\n") + "\n"
    }
}
