import Foundation

/// Writes unified conversations into kimi-code's session store so `kimi --session <id>` resumes them.
struct KimiCodeMigrator: SessionMigrator {
    let target: AgentSource = .kimiCode

    private enum Constants {
        static let kimiDir = ".kimi-code"
        static let sessionsDir = "sessions"
        static let indexFile = "session_index.jsonl"
        static let workspacesFile = "workspaces.json"
        static let sessionPrefix = "session_"
        static let wireFile = "wire.jsonl"
        static let stateFile = "state.json"
    }

    private let fileSystem: any FileSystemProtocol
    private let builder: KimiCodeWireBuilder
    private let workingDirectoryProvider: @Sendable () -> String

    init(
        fileSystem: any FileSystemProtocol = DefaultFileSystem(),
        builder: KimiCodeWireBuilder = KimiCodeWireBuilder(),
        workingDirectoryProvider: @escaping @Sendable () -> String = { FileManager.default.currentDirectoryPath }
    ) {
        self.fileSystem = fileSystem
        self.builder = builder
        self.workingDirectoryProvider = workingDirectoryProvider
    }

    func migrate(_ conversation: UnifiedConversation) throws -> MigrationResult {
        guard !conversation.messages.isEmpty else { throw MigrationError.sessionEmpty }

        let root = conversation.projectPath ?? workingDirectoryProvider()
        let origin = MigrationOrigin(
            originId: conversation.id,
            originSource: conversation.source,
            originMessageCount: conversation.messages.count,
            originDigest: MigrationDeduplicator.originDigest(for: conversation)
        )
        if let existing = findExistingMigration(origin: origin) {
            throw MigrationError.alreadyMigrated(existingPath: existing)
        }

        let sessionId = Constants.sessionPrefix + UUID().uuidString.lowercased()
        let workspaceId = KimiCodeWorkspace.workspaceId(forRoot: root)
        let sessionDir = sessionsBase()
            .appendingPathComponent(workspaceId, isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
        let mainDir = sessionDir.appendingPathComponent(KimiCodeWireBuilder.mainAgentPath, isDirectory: true)

        // Compute the upsert first: a corrupt registry fails closed and must abort
        // before any session file exists.
        let updatedWorkspaces = try makeWorkspacesUpsert(workspaceId: workspaceId, root: root)

        let doc = builder.makeDocument(
            conversation: conversation,
            sessionId: sessionId,
            sessionDirPath: sessionDir.path,
            workDir: root
        )

        try fileSystem.createDirectory(at: mainDir, withIntermediateDirectories: true, attributes: nil)
        try write(doc.stateJSON, to: sessionDir.appendingPathComponent(Constants.stateFile))
        try write(doc.wireJSONL, to: mainDir.appendingPathComponent(Constants.wireFile))
        try writeData(updatedWorkspaces, to: kimiBase().appendingPathComponent(Constants.workspacesFile))
        // The index append is the commit point: dedup and kimi's listing are index-driven,
        // so a failure before this line leaves only an invisible unindexed orphan.
        try appendIndexLine(sessionId: sessionId, sessionDir: sessionDir, root: root)

        logger.info("💾 Wrote kimi-code session messages=\(conversation.messages.count) path=\(sessionDir.path)")
        return .written(path: sessionDir.path, sessionID: sessionId)
    }

    private func kimiBase() -> URL {
        fileSystem.homeDirectoryForCurrentUser.appendingPathComponent(Constants.kimiDir)
    }

    private func sessionsBase() -> URL {
        kimiBase().appendingPathComponent(Constants.sessionsDir)
    }

    private func write(_ contents: String, to file: URL) throws {
        try writeData(Data(contents.utf8), to: file)
    }

    private func writeData(_ data: Data, to file: URL) throws {
        guard fileSystem.createFile(atPath: file.path, contents: data, attributes: nil) else {
            throw MigrationError.writeFailed("Failed to write \(file.lastPathComponent)")
        }
    }

    private func makeWorkspacesUpsert(workspaceId: String, root: String) throws -> Data {
        let workspacesFile = kimiBase().appendingPathComponent(Constants.workspacesFile)
        let timestamp = MigratorUtils.isoFormatter.string(from: Date())
        return try KimiCodeWorkspace.upsertWorkspaces(
            existing: fileSystem.contents(atPath: workspacesFile.path),
            workspaceId: workspaceId,
            root: root,
            name: URL(fileURLWithPath: root).lastPathComponent,
            timestamp: timestamp
        )
    }

    private func appendIndexLine(sessionId: String, sessionDir: URL, root: String) throws {
        let indexFile = kimiBase().appendingPathComponent(Constants.indexFile)
        guard let line = KimiCodeWorkspace.indexLine(
            sessionId: sessionId, sessionDir: sessionDir.path, workDir: root
        ) else {
            throw MigrationError.writeFailed("Failed to encode session index entry")
        }
        var indexText = fileSystem.contents(atPath: indexFile.path).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        if !indexText.isEmpty, !indexText.hasSuffix("\n") { indexText += "\n" }
        indexText += line + "\n"
        try write(indexText, to: indexFile)
    }

    /// Index-driven (not directory-walking) so it resolves known paths and behaves identically
    /// against the real FS and the test mock.
    private func findExistingMigration(origin: MigrationOrigin) -> String? {
        let indexFile = kimiBase().appendingPathComponent(Constants.indexFile)
        guard let data = fileSystem.contents(atPath: indexFile.path),
              let text = String(data: data, encoding: .utf8) else { return nil }

        for line in text.split(separator: "\n") {
            guard let entryData = line.data(using: .utf8),
                  let entry = try? JSONDecoder().decode(KimiCodeWorkspace.IndexEntry.self, from: entryData)
            else { continue }
            let stateFile = URL(fileURLWithPath: entry.sessionDir).appendingPathComponent(Constants.stateFile)
            guard let stateData = fileSystem.contents(atPath: stateFile.path),
                  let meta = decodeMeta(from: stateData) else { continue }
            if MigrationDeduplicator.matches(meta, origin) {
                return entry.sessionDir
            }
        }
        return nil
    }

    private func decodeMeta(from data: Data) -> MigrationMeta? {
        struct Envelope: Decodable {
            struct Custom: Decodable {
                let ctxmvMigration: MigrationMeta?
                enum CodingKeys: String, CodingKey { case ctxmvMigration = "ctxmv_migration" }
            }

            let custom: Custom?
        }
        return (try? JSONDecoder().decode(Envelope.self, from: data))?.custom?.ctxmvMigration
    }
}
