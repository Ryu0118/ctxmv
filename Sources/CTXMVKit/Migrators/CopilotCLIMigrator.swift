import Foundation

/// Imports unified conversations into Copilot CLI's supported session format.
struct CopilotCLIMigrator: SessionMigrator {
    let target: AgentSource = .copilotCLI

    private enum StorageComponent: String {
        case sessionState = "session-state"
        case migrationMarkers = "ctxmv-migrations"
        case copilotCLI = "copilot-cli"
        case jsonExtension = "json"
    }

    private struct MigrationMarker: Codable {
        let targetSessionID: String
        let origin: MigrationMeta
    }

    private let fileSystem: any FileSystemProtocol
    private let copilotHome: URL
    private let importer: any CopilotSessionImporter
    private let sessionBuilder: CopilotSemanticSessionBuilder

    init(
        fileSystem: any FileSystemProtocol,
        copilotHome: URL,
        importer: any CopilotSessionImporter = CopilotCommandSessionImporter(),
        sessionBuilder: CopilotSemanticSessionBuilder = CopilotSemanticSessionBuilder()
    ) {
        self.fileSystem = fileSystem
        self.copilotHome = copilotHome
        self.importer = importer
        self.sessionBuilder = sessionBuilder
    }

    func migrate(_ conversation: UnifiedConversation) throws -> MigrationResult {
        let jsonl = try semanticJSONL(for: conversation)
        let origin = makeOrigin(for: conversation)
        let sessionsDirectory = copilotHome.appendingPathComponent(
            StorageComponent.sessionState.rawValue,
            isDirectory: true
        )
        let markerDirectory = migrationMarkerDirectory

        if let existingPath = findExistingMigration(
            origin: origin,
            in: markerDirectory,
            sessionsDirectory: sessionsDirectory
        ) {
            throw MigrationError.alreadyMigrated(existingPath: existingPath)
        }

        let workingDirectory = conversation.projectPath.flatMap { $0.isEmpty ? nil : $0 }
            ?? fileSystem.homeDirectoryForCurrentUser.path
        let sessionID: String
        do {
            sessionID = try importer.importSession(
                semanticJSONL: jsonl,
                workingDirectory: workingDirectory,
                copilotHome: copilotHome
            )
        } catch let error as MigrationError {
            throw error
        } catch {
            throw MigrationError.writeFailed("Copilot CLI session import failed.")
        }

        guard let uuid = UUID(uuidString: sessionID) else {
            throw MigrationError.writeFailed("Copilot CLI returned an invalid session ID.")
        }
        let canonicalSessionID = uuid.uuidString.lowercased()
        let sessionDirectory = sessionsDirectory.appendingPathComponent(canonicalSessionID, isDirectory: true)
        try fileSystem.createDirectory(at: sessionDirectory, withIntermediateDirectories: true, attributes: nil)
        try writeMigrationMarker(for: origin, sessionID: canonicalSessionID, in: markerDirectory)

        logger.info("""
        💾 Imported Copilot session messages=\(conversation.messages.count) path=\(sessionDirectory.path)
        """)
        return .written(path: sessionDirectory.path, sessionID: canonicalSessionID)
    }

    private func semanticJSONL(for conversation: UnifiedConversation) throws -> String {
        guard conversation.messages.contains(where: { $0.role == .user || $0.role == .assistant }) else {
            throw MigrationError.sessionEmpty
        }
        guard let jsonl = sessionBuilder.jsonl(for: conversation) else {
            throw MigrationError.writeFailed("Could not encode the Copilot session transcript.")
        }
        return jsonl
    }

    private func makeOrigin(for conversation: UnifiedConversation) -> MigrationOrigin {
        MigrationOrigin(
            originId: conversation.id,
            originSource: conversation.source,
            originMessageCount: conversation.messages.count,
            originDigest: MigrationDeduplicator.originDigest(for: conversation)
        )
    }

    private var migrationMarkerDirectory: URL {
        // Keep ctxmv metadata outside Copilot-managed session directories and files.
        copilotHome
            .appendingPathComponent(StorageComponent.migrationMarkers.rawValue, isDirectory: true)
            .appendingPathComponent(StorageComponent.copilotCLI.rawValue, isDirectory: true)
    }

    private func findExistingMigration(
        origin: MigrationOrigin,
        in markerDirectory: URL,
        sessionsDirectory: URL
    ) -> String? {
        let markerURL = markerURL(for: origin, in: markerDirectory)
        guard let data = fileSystem.contents(atPath: markerURL.path),
              let marker = try? MigratorUtils.jsonDecoder.decode(MigrationMarker.self, from: data),
              marker.origin.type == MigrationMeta.migrationType,
              MigrationDeduplicator.matches(marker.origin, origin),
              let uuid = UUID(uuidString: marker.targetSessionID) else { return nil }
        return sessionsDirectory.appendingPathComponent(uuid.uuidString.lowercased(), isDirectory: true).path
    }

    private func writeMigrationMarker(for origin: MigrationOrigin, sessionID: String, in markerDirectory: URL) throws {
        let marker = MigrationMarker(
            targetSessionID: sessionID,
            origin: MigrationDeduplicator.makeMeta(origin: origin)
        )
        guard let data = try? MigratorUtils.jsonEncoder.encode(marker) else {
            throw MigrationError.writeFailed("Could not encode the Copilot migration marker.")
        }
        try fileSystem.createDirectory(
            at: markerDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let markerURL = markerURL(for: origin, in: markerDirectory)
        guard fileSystem.createFile(
            atPath: markerURL.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw MigrationError.writeFailed(
                "Copilot session was imported but its migration marker could not be written."
            )
        }
    }

    private func markerURL(for origin: MigrationOrigin, in markerDirectory: URL) -> URL {
        markerDirectory.appendingPathComponent(MigrationDeduplicator.migrationKey(for: origin))
            .appendingPathExtension(StorageComponent.jsonExtension.rawValue)
    }
}
