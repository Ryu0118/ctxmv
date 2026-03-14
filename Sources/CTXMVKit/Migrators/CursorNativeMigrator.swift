import Foundation

/// Orchestrates native Cursor migration by delegating storage-specific work.
struct CursorNativeMigrator: SessionMigrator, Sendable {
    let target: AgentSource = .cursor

    private enum Defaults {
        static let mode = "default"
        static let name = "Migrated Chat"
        static let targetFormatVersion = 2
    }

    private let fileSystem: FileSystemProtocol
    private let pathResolver: CursorMigrationPathResolver
    private let blobBuilder = CursorConversationBlobBuilder()
    private let databaseWriter = CursorStoreDatabaseWriter()
    private let scanner: CursorMigrationScanner
    private let transcriptWriter: CursorTranscriptWriter

    init(
        fileSystem: FileSystemProtocol = DefaultFileSystem(),
        projectPath: String? = nil
    ) {
        self.fileSystem = fileSystem
        pathResolver = CursorMigrationPathResolver(
            projectPath: projectPath,
            homeDirectory: fileSystem.homeDirectoryForCurrentUser
        )
        scanner = CursorMigrationScanner(
            fileSystem: fileSystem,
            targetFormatVersion: Defaults.targetFormatVersion
        )
        transcriptWriter = CursorTranscriptWriter(fileSystem: fileSystem)
    }

    func migrate(_ conversation: UnifiedConversation) throws -> MigrationResult {
        guard !conversation.messages.isEmpty else {
            throw MigrationError.sessionEmpty
        }

        let sessionId = UUID().uuidString.lowercased()
        let paths = migrationPaths(for: conversation, sessionId: sessionId)
        let originDigest = MigrationDeduplicator.originDigest(for: conversation)

        if let existing = scanner.findExistingMigration(
            originId: conversation.id,
            originSource: conversation.source,
            originMessageCount: conversation.messages.count,
            originDigest: originDigest,
            in: paths.chatsWorkspaceDirectory
        ) {
            throw MigrationError.alreadyMigrated(existingPath: existing)
        }

        let sessionDirectory = paths.chatsWorkspaceDirectory
            .appendingPathComponent(sessionId, isDirectory: true)
        try fileSystem.createDirectory(at: sessionDirectory, withIntermediateDirectories: true, attributes: nil)

        let blobs = blobBuilder.blobs(for: conversation, projectPath: paths.projectPath)
        let metadataHex = cursorMetadataHex(
            sessionId: sessionId,
            rootBlobID: blobs.rootBlobID,
            createdAt: conversation.createdAt,
            model: conversation.model
        )
        let migrationMetaJSON = migrationMetadataJSON(
            originId: conversation.id,
            originSource: conversation.source,
            originMessageCount: conversation.messages.count,
            originDigest: originDigest
        )

        let databasePath = sessionDirectory.appendingPathComponent("store.db").path
        // Write both Cursor backends: `store.db` powers the native session store,
        // while the transcript file preserves compatibility with transcript-based fallbacks.
        try databaseWriter.writeStoreDatabase(
            at: databasePath,
            messageBlobs: blobs.messageBlobs,
            metadataHex: metadataHex,
            migrationMetaJSON: migrationMetaJSON
        )
        try transcriptWriter.write(conversation, to: paths.transcriptFile)

        logger.info("💾 Wrote native Cursor session messages=\(conversation.messages.count) path=\(databasePath)")
        return .written(path: databasePath, sessionID: sessionId)
    }

    private func migrationPaths(for conversation: UnifiedConversation, sessionId: String) -> CursorMigrationPaths {
        let projectPath = pathResolver.projectPath(for: conversation)
        let chatsWorkspaceDirectory = pathResolver.chatsWorkspaceDirectory(for: projectPath)
        let transcriptFile = pathResolver.transcriptFile(for: projectPath, sessionId: sessionId)

        return CursorMigrationPaths(
            projectPath: projectPath,
            chatsWorkspaceDirectory: chatsWorkspaceDirectory,
            transcriptFile: transcriptFile
        )
    }

    /// Encodes Cursor's primary session metadata record as hex-wrapped JSON for the `meta` table.
    private func cursorMetadataHex(
        sessionId: String,
        rootBlobID: String,
        createdAt: Date,
        model: String?
    ) -> String {
        let metadata = CursorSessionMeta(
            agentId: sessionId,
            latestRootBlobId: rootBlobID,
            name: Defaults.name,
            mode: Defaults.mode,
            createdAt: Int64(createdAt.timeIntervalSince1970 * 1000.0),
            lastUsedModel: (model?.isEmpty == false) ? model : nil
        )

        guard let data = try? MigratorUtils.jsonEncoder.encode(metadata),
              let json = String(data: data, encoding: .utf8)
        else {
            return ""
        }

        return MigratorUtils.hexString(Data(json.utf8))
    }

    /// Serializes ctxmv's migration bookkeeping JSON stored alongside Cursor's native metadata.
    private func migrationMetadataJSON(
        originId: String,
        originSource: AgentSource,
        originMessageCount: Int,
        originDigest: String
    ) -> String {
        let metadata = MigrationMeta(
            type: MigrationMeta.migrationType,
            originId: originId,
            originSource: originSource.rawValue,
            originMessageCount: originMessageCount,
            originDigest: originDigest,
            targetFormatVersion: Defaults.targetFormatVersion
        )

        guard let data = try? MigratorUtils.jsonEncoder.encode(metadata),
              let json = String(data: data, encoding: .utf8)
        else {
            return ""
        }

        return json
    }
}

private struct CursorSessionMeta: Encodable, Sendable {
    let agentId: String
    let latestRootBlobId: String
    let name: String
    let mode: String
    let createdAt: Int64
    let lastUsedModel: String?
}
