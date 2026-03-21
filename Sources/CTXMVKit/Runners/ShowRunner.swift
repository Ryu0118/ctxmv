import Foundation
import Logging

/// Finds a session and prints its conversation messages.
package struct ShowRunner {
    private enum Defaults {
        static let autoLargeSessionMessageLimit = 100
        static let largeSessionByteThreshold: Int64 = 1_048_576
    }

    private struct LocatedSession {
        let conversation: UnifiedConversation
        let summary: SessionSummary?
        let appliedMessageLimit: Int?
        let autoLimited: Bool
    }

    private let sessionID: String
    private let source: AgentSource?
    private let messageLimit: Int?
    private let largeSessionByteThreshold: Int64?
    private let autoLargeSessionMessageLimit: Int
    private let formatter: ShowConversationFormatter

    private let readers: [any SessionReader]

    package init(
        sessionID: String,
        source: AgentSource? = nil,
        raw: Bool = false,
        messageLimit: Int? = nil,
        largeSessionByteThreshold: Int64? = Defaults.largeSessionByteThreshold,
        autoLargeSessionMessageLimit: Int = Defaults.autoLargeSessionMessageLimit,
        fileSystem: any FileSystemProtocol = DefaultFileSystem(),
        sqlite: any SQLiteReader = DefaultSQLiteReader()
    ) {
        self.sessionID = sessionID
        self.source = source
        self.messageLimit = messageLimit
        self.largeSessionByteThreshold = largeSessionByteThreshold
        self.autoLargeSessionMessageLimit = autoLargeSessionMessageLimit
        formatter = ShowConversationFormatter(raw: raw)
        readers = SessionReaderFactory.make(fileSystem: fileSystem, sqlite: sqlite)
    }

    /// Creates a runner with injected readers for tests.
    package init(
        sessionID: String,
        source: AgentSource? = nil,
        raw: Bool = false,
        messageLimit: Int? = nil,
        largeSessionByteThreshold: Int64? = Defaults.largeSessionByteThreshold,
        autoLargeSessionMessageLimit: Int = Defaults.autoLargeSessionMessageLimit,
        readers: [any SessionReader]
    ) {
        self.sessionID = sessionID
        self.source = source
        self.messageLimit = messageLimit
        self.largeSessionByteThreshold = largeSessionByteThreshold
        self.autoLargeSessionMessageLimit = autoLargeSessionMessageLimit
        formatter = ShowConversationFormatter(raw: raw)
        self.readers = readers
    }

    package func run() async throws {
        guard let located = try await findLocatedSession() else {
            logger.error("Session '\(sessionID)' not found.")
            return
        }

        if let warning = truncationWarning(for: located) {
            logger.warning("\(warning)")
        }

        logger.info("\(formatter.format(located.conversation))")
    }

    package func findSession() async throws -> UnifiedConversation? {
        try await findLocatedSession()?.conversation
    }

    /// Tries a direct load first for full-length IDs, then falls back to listing all sessions.
    private func findLocatedSession() async throws -> LocatedSession? {
        logger.debug("Finding session", metadata: ["id": "\(sessionID)"])

        let candidateReaders = filteredReaders()

        // Fast path: full UUID — skip expensive listSessions and load directly.
        if sessionID.count >= 36 {
            logger.info("⏳ Loading session \(sessionID)...")
            if let located = try await loadFallbackSession(using: candidateReaders) {
                return located
            }
        }

        // Slow path: short/prefix/suffix ID needs summary scan to resolve.
        let sourceLabel = candidateReaders.map(\.source.rawValue).joined(separator: ", ")
        logger.info("⏳ Scanning sessions from [\(sourceLabel)]...")
        let summaries = try await listSessions(from: candidateReaders)
        if let summary = matchingSummary(in: summaries) {
            return try await loadLocatedSession(from: summary, using: candidateReaders)
        }

        // Last resort for full IDs that weren't found via direct load either.
        if sessionID.count < 36 {
            return try await loadFallbackSession(using: candidateReaders)
        }
        return nil
    }

    private func listSessions(from candidateReaders: [any SessionReader]) async throws -> [SessionSummary] {
        await withTaskGroup(of: [SessionSummary].self, returning: [SessionSummary].self) { group in
            for reader in candidateReaders {
                group.addTask {
                    await (try? reader.listSessions()) ?? []
                }
            }
            var all: [SessionSummary] = []
            for await batch in group {
                all.append(contentsOf: batch)
            }
            return all
        }.sorted { $0.createdAt > $1.createdAt }
    }

    private func filteredReaders() -> [any SessionReader] {
        guard let source else { return readers }
        return readers.filter { $0.source == source }
    }

    /// Supports exact IDs plus the short suffix shown by `ctxmv list`.
    private func matchingSummary(in summaries: [SessionSummary]) -> SessionSummary? {
        if let exact = summaries.first(where: { $0.id == sessionID }) {
            return exact
        }

        if sessionID.count < 36 {
            if let prefixMatch = summaries.first(where: { $0.id.hasPrefix(sessionID) }) {
                return prefixMatch
            }
            // `ctxmv list` displays last 8 chars, so allow suffix lookup as shorthand.
            return summaries.first { $0.id.hasSuffix(sessionID) }
        }
        return nil
    }

    private func loadLocatedSession(
        from summary: SessionSummary,
        using candidateReaders: [any SessionReader]
    ) async throws -> LocatedSession? {
        let appliedLimit = resolvedMessageLimit(for: summary.byteSize)
        guard let reader = candidateReaders.first(where: { $0.source == summary.source }),
              let conversation = try? await reader.loadSession(
                  id: summary.id,
                  storagePath: summary.storagePath,
                  limit: appliedLimit
              )
        else {
            return nil
        }

        logger.info("🔍 Found session via summary source=\(conversation.source.rawValue)")
        return makeLocatedSession(
            conversation: conversation,
            summary: summary,
            appliedMessageLimit: appliedLimit
        )
    }

    private func loadFallbackSession(using candidateReaders: [any SessionReader]) async throws -> LocatedSession? {
        let fallbackLimit = resolvedMessageLimit(for: nil)
        let located: LocatedSession? = await withTaskGroup(of: LocatedSession?.self) { group in
            for reader in candidateReaders {
                group.addTask { [self] in
                    guard let conversation = try? await reader.loadSession(id: sessionID, limit: fallbackLimit) else {
                        return nil
                    }
                    return makeLocatedSession(
                        conversation: conversation,
                        summary: nil,
                        appliedMessageLimit: fallbackLimit
                    )
                }
            }
            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }
        if let located {
            logger.info("🔍 Found session via exact fallback source=\(located.conversation.source.rawValue)")
        }
        return located
    }

    private func makeLocatedSession(
        conversation: UnifiedConversation,
        summary: SessionSummary?,
        appliedMessageLimit: Int?
    ) -> LocatedSession {
        LocatedSession(
            conversation: conversation,
            summary: summary,
            appliedMessageLimit: appliedMessageLimit,
            autoLimited: isAutoLimited(byteSize: summary?.byteSize, appliedMessageLimit: appliedMessageLimit)
        )
    }

    /// Chooses an explicit limit when provided, otherwise auto-limits very large sessions.
    private func resolvedMessageLimit(for byteSize: Int64?) -> Int? {
        if let messageLimit {
            return messageLimit
        }
        guard let largeSessionByteThreshold else {
            return nil
        }
        guard let byteSize else {
            return autoLargeSessionMessageLimit
        }
        return byteSize > largeSessionByteThreshold ? autoLargeSessionMessageLimit : nil
    }

    private func isAutoLimited(byteSize: Int64?, appliedMessageLimit: Int?) -> Bool {
        guard messageLimit == nil,
              largeSessionByteThreshold != nil,
              let appliedMessageLimit,
              appliedMessageLimit == autoLargeSessionMessageLimit
        else {
            return false
        }

        guard let byteSize else { return true }
        guard let largeSessionByteThreshold else { return false }
        return byteSize > largeSessionByteThreshold
    }

    /// Explains why output was truncated so callers understand whether size detection was certain.
    private func truncationWarning(for located: LocatedSession) -> String? {
        guard located.autoLimited,
              let appliedMessageLimit = located.appliedMessageLimit
        else {
            return nil
        }

        if let byteSize = located.summary?.byteSize, let largeSessionByteThreshold {
            return "Large session detected (\(byteSize.formattedByteCount()) > \(largeSessionByteThreshold.formattedByteCount())). Showing the latest \(appliedMessageLimit) messages. Use --all to bypass."
        }

        return "Session size could not be determined safely. Showing the latest \(appliedMessageLimit) messages. Use --all to bypass."
    }
}
