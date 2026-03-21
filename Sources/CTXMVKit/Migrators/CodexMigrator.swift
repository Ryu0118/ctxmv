import Foundation

/// Writes unified conversations into Codex's rollout format.
struct CodexMigrator: SessionMigrator, Sendable {
    let target: AgentSource = .codex

    private let fileSystem: any FileSystemProtocol
    private let jsonlBuilder: CodexSessionJSONLBuilder

    private enum StorageDefaults {
        static let sessionsDirectory = ".codex/sessions"
        /// Snap remaps $HOME to ~/snap/codex/<rev>/, so codex_home = $HOME
        /// and sessions live at $HOME/sessions/ (no .codex prefix).
        static let snapSessionsDirectory = "snap/codex/current/sessions"
        static let filePrefix = "rollout"
    }

    /// Breaks a session timestamp into both path components and the rollout filename stem.
    private struct SessionDateParts: Sendable {
        let year: Int
        let month: Int
        let day: Int
        let timestamp: String

        init(date: Date, calendar: Calendar = .current) {
            year = calendar.component(.year, from: date)
            month = calendar.component(.month, from: date)
            day = calendar.component(.day, from: date)

            let hour = calendar.component(.hour, from: date)
            let minute = calendar.component(.minute, from: date)
            let second = calendar.component(.second, from: date)
            timestamp = String(format: "%04d-%02d-%02dT%02d-%02d-%02d", year, month, day, hour, minute, second)
        }

        var monthPathComponent: String {
            String(format: "%02d", month)
        }

        var dayPathComponent: String {
            String(format: "%02d", day)
        }
    }

    /// Collects the destination directory and final rollout file path.
    private struct SessionOutputLocation: Sendable {
        let directory: URL
        let fileURL: URL
    }

    init(
        fileSystem: any FileSystemProtocol = DefaultFileSystem(),
        jsonlBuilder: CodexSessionJSONLBuilder = CodexSessionJSONLBuilder()
    ) {
        self.fileSystem = fileSystem
        self.jsonlBuilder = jsonlBuilder
    }

    func migrate(_ conversation: UnifiedConversation) throws -> MigrationResult {
        try validate(conversation)

        let sessionsBase = sessionsBaseDirectory()
        let originDigest = MigrationDeduplicator.originDigest(for: conversation)
        try ensureNoExistingMigration(
            for: conversation,
            originDigest: originDigest,
            sessionsBase: sessionsBase
        )

        let sessionId = UUID().uuidString.lowercased()
        let output = makeOutputLocation(
            createdAt: conversation.createdAt,
            sessionId: sessionId,
            sessionsBase: sessionsBase
        )

        try writeSessionFile(
            conversation: conversation,
            sessionId: sessionId,
            to: output
        )

        logger.info("💾 Wrote Codex session messages=\(conversation.messages.count) path=\(output.fileURL.path)")
        return .written(path: output.fileURL.path, sessionID: sessionId)
    }

    func jsonl(for conversation: UnifiedConversation, sessionId: String) -> String {
        jsonlBuilder.jsonl(for: conversation, sessionId: sessionId)
    }

    private func validate(_ conversation: UnifiedConversation) throws {
        guard !conversation.messages.isEmpty else {
            throw MigrationError.sessionEmpty
        }
    }

    /// Resolves the Codex sessions directory following the same logic as Codex itself:
    /// 1. `CODEX_HOME` env var → `$CODEX_HOME/sessions/`
    /// 2. Snap-packaged Codex (~/snap/codex/ exists) → `~/snap/codex/current/sessions/`
    /// 3. Default → `~/.codex/sessions/`
    private func sessionsBaseDirectory() -> URL {
        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"], !codexHome.isEmpty {
            return URL(fileURLWithPath: codexHome).appendingPathComponent("sessions")
        }
        let home = fileSystem.homeDirectoryForCurrentUser
        let snapDir = home.appendingPathComponent("snap/codex")
        if fileSystem.fileExists(atPath: snapDir.path) {
            return home.appendingPathComponent(StorageDefaults.snapSessionsDirectory)
        }
        return home.appendingPathComponent(StorageDefaults.sessionsDirectory)
    }

    private func ensureNoExistingMigration(
        for conversation: UnifiedConversation,
        originDigest: String,
        sessionsBase: URL
    ) throws {
        let origin = MigrationOrigin(
            originId: conversation.id,
            originSource: conversation.source,
            originMessageCount: conversation.messages.count,
            originDigest: originDigest
        )
        if let existing = MigrationDeduplicator.findExistingMigrationRecursive(
            origin: origin,
            in: sessionsBase,
            fileSystem: fileSystem
        ) {
            throw MigrationError.alreadyMigrated(existingPath: existing)
        }
    }

    private func makeOutputLocation(
        createdAt: Date,
        sessionId: String,
        sessionsBase: URL
    ) -> SessionOutputLocation {
        // Match Codex's rollout naming so `codex resume` recognizes the file layout.
        let dateParts = SessionDateParts(date: createdAt)
        let directory = sessionsBase
            .appendingPathComponent(String(dateParts.year), isDirectory: true)
            .appendingPathComponent(dateParts.monthPathComponent, isDirectory: true)
            .appendingPathComponent(dateParts.dayPathComponent, isDirectory: true)
        let fileName = "\(StorageDefaults.filePrefix)-\(dateParts.timestamp)-\(sessionId).jsonl"

        return SessionOutputLocation(
            directory: directory,
            fileURL: directory.appendingPathComponent(fileName)
        )
    }

    private func writeSessionFile(
        conversation: UnifiedConversation,
        sessionId: String,
        to output: SessionOutputLocation
    ) throws {
        try fileSystem.createDirectory(at: output.directory, withIntermediateDirectories: true, attributes: nil)
        let data = try makeJSONLData(conversation: conversation, sessionId: sessionId)
        _ = fileSystem.createFile(atPath: output.fileURL.path, contents: data, attributes: nil)
    }

    private func makeJSONLData(
        conversation: UnifiedConversation,
        sessionId: String
    ) throws -> Data {
        let jsonlContent = jsonl(for: conversation, sessionId: sessionId)
        guard let data = jsonlContent.data(using: .utf8) else {
            throw MigrationError.writeFailed("Failed to encode JSONL as UTF-8")
        }
        return data
    }
}
