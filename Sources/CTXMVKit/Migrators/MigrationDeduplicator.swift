#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif
import Foundation

/// Records the source snapshot for a migrated conversation.
struct MigrationMeta: Codable, Sendable {
    static let migrationType = "ctxmv_migration"

    let type: String // "ctxmv_migration"
    let originId: String
    let originSource: String
    let originMessageCount: Int
    let originDigest: String?
    let targetFormatVersion: Int?
}

private struct ClaudeProgressMetaLine: Codable {
    let type: String
    let sessionId: String
    let timestamp: String
    let uuid: String
    let data: MigrationMeta
}

/// Detects whether a conversation snapshot has already been migrated.
enum MigrationDeduplicator {
    private static let decoder = JSONDecoder()

    static func makeMeta(
        originId: String,
        originSource: AgentSource,
        originMessageCount: Int,
        originDigest: String
    ) -> MigrationMeta {
        MigrationMeta(
            type: MigrationMeta.migrationType,
            originId: originId,
            originSource: originSource.rawValue,
            originMessageCount: originMessageCount,
            originDigest: originDigest,
            targetFormatVersion: nil
        )
    }

    static func encodeMeta(
        originId: String,
        originSource: AgentSource,
        originMessageCount: Int,
        originDigest: String
    ) -> String? {
        let meta = makeMeta(
            originId: originId,
            originSource: originSource,
            originMessageCount: originMessageCount,
            originDigest: originDigest
        )
        guard let data = try? MigratorUtils.jsonEncoder.encode(meta) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func encodeClaudeCodeMeta(
        originId: String,
        originSource: AgentSource,
        originMessageCount: Int,
        originDigest: String,
        sessionId: String,
        timestamp: String
    ) -> String? {
        let meta = makeMeta(
            originId: originId,
            originSource: originSource,
            originMessageCount: originMessageCount,
            originDigest: originDigest
        )
        let wrapped = ClaudeProgressMetaLine(
            type: "progress",
            sessionId: sessionId,
            timestamp: timestamp,
            uuid: UUID().uuidString.lowercased(),
            data: meta
        )
        guard let data = try? MigratorUtils.jsonEncoder.encode(wrapped) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func findExistingMigration(
        originId: String,
        originSource: AgentSource,
        originMessageCount: Int,
        originDigest: String,
        in directory: URL,
        fileSystem: any FileSystemProtocol,
        allowBareMetaLine: Bool = true
    ) -> String? {
        guard fileSystem.fileExists(atPath: directory.path) else { return nil }

        let jsonlFiles: [URL]
        if let contents = try? fileSystem.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) {
            jsonlFiles = contents.filter { $0.pathExtension == "jsonl" }
        } else {
            return nil
        }

        for file in jsonlFiles {
            guard let meta = readMigrationMeta(
                from: file,
                fileSystem: fileSystem,
                allowBareMetaLine: allowBareMetaLine
            ) else { continue }
            guard meta.originId == originId, meta.originSource == originSource.rawValue else { continue }

            // Strict dedup: only exact same origin snapshot is considered duplicate.
            // Prefer digest (full history signature). For legacy files without digest,
            // fall back to exact message count equality.
            if let existingDigest = meta.originDigest {
                if existingDigest == originDigest {
                    return file.path
                }
                continue
            }

            if meta.originMessageCount == originMessageCount {
                return file.path
            }
        }

        return nil
    }

    static func findExistingMigrationRecursive(
        originId: String,
        originSource: AgentSource,
        originMessageCount: Int,
        originDigest: String,
        in baseDirectory: URL,
        fileSystem: any FileSystemProtocol,
        allowBareMetaLine: Bool = true
    ) -> String? {
        guard fileSystem.fileExists(atPath: baseDirectory.path) else { return nil }

        return nestedDirectories(
            in: baseDirectory,
            depth: 3,
            fileSystem: fileSystem
        )
        .lazy
        .compactMap { leafDirectory in
            findExistingMigration(
                originId: originId,
                originSource: originSource,
                originMessageCount: originMessageCount,
                originDigest: originDigest,
                in: leafDirectory,
                fileSystem: fileSystem,
                allowBareMetaLine: allowBareMetaLine
            )
        }
        .first
    }

    static func originDigest(for conversation: UnifiedConversation) -> String {
        var canonical = ""
        canonical.reserveCapacity(conversation.messages.reduce(0) { $0 + $1.content.count + 64 })
        for message in conversation.messages {
            let timestamp = message.timestamp.map { MigratorUtils.isoFormatter.string(from: $0) } ?? ""
            let decoded = message.decodedContent(for: conversation.source)
            canonical.append(message.role.rawValue)
            canonical.append("\u{1f}")
            canonical.append(timestamp)
            canonical.append("\u{1f}")
            canonical.append(decoded)
            canonical.append("\u{1e}")
        }
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return MigratorUtils.hexString(Data(digest))
    }

    private static func readMigrationMeta(
        from file: URL,
        fileSystem: any FileSystemProtocol,
        allowBareMetaLine: Bool
    ) -> MigrationMeta? {
        guard let data = fileSystem.contents(atPath: file.path),
              let content = String(data: data, encoding: .utf8) else { return nil }

        guard let firstLine = content.components(separatedBy: .newlines).first,
              !firstLine.isEmpty,
              let lineData = firstLine.data(using: .utf8) else { return nil }

        if allowBareMetaLine,
           let meta = try? decoder.decode(MigrationMeta.self, from: lineData),
           meta.type == MigrationMeta.migrationType
        {
            return meta
        }

        if let wrapped = try? decoder.decode(ClaudeProgressMetaLine.self, from: lineData),
           wrapped.data.type == MigrationMeta.migrationType
        {
            return wrapped.data
        }

        return nil
    }

    private static func nestedDirectories(
        in directory: URL,
        depth: Int,
        fileSystem: any FileSystemProtocol
    ) -> [URL] {
        guard depth > 0 else { return [directory] }

        return childDirectories(in: directory, fileSystem: fileSystem)
            .flatMap { childDirectory in
                nestedDirectories(
                    in: childDirectory,
                    depth: depth - 1,
                    fileSystem: fileSystem
                )
            }
    }

    private static func childDirectories(
        in directory: URL,
        fileSystem: any FileSystemProtocol
    ) -> [URL] {
        ((try? fileSystem.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? [])
            .filter { isDirectory($0, fileSystem: fileSystem) }
    }

    private static func isDirectory(
        _ url: URL,
        fileSystem: any FileSystemProtocol
    ) -> Bool {
        var isDirectory = ObjCBool(false)
        guard fileSystem.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
        return isDirectory.boolValue
    }
}
