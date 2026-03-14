import Foundation
import Logging

/// Finds a session and prints its conversation messages.
package struct ShowRunner: Sendable {
    private enum Defaults {
        static let autoLargeSessionMessageLimit = 100
        static let largeSessionByteThreshold: Int64 = 1_048_576
    }

    private struct LocatedSession: Sendable {
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

    private let providers: [SessionProvider]

    package init(
        sessionID: String,
        source: AgentSource? = nil,
        raw: Bool = false,
        messageLimit: Int? = nil,
        largeSessionByteThreshold: Int64? = Defaults.largeSessionByteThreshold,
        autoLargeSessionMessageLimit: Int = Defaults.autoLargeSessionMessageLimit,
        fileSystem: FileSystemProtocol = DefaultFileSystem(),
        sqlite: SQLiteProvider = DefaultSQLiteProvider()
    ) {
        self.sessionID = sessionID
        self.source = source
        self.messageLimit = messageLimit
        self.largeSessionByteThreshold = largeSessionByteThreshold
        self.autoLargeSessionMessageLimit = autoLargeSessionMessageLimit
        formatter = ShowConversationFormatter(raw: raw)
        providers = SessionProviderFactory.make(fileSystem: fileSystem, sqlite: sqlite)
    }

    /// Creates a runner with injected providers for tests.
    package init(
        sessionID: String,
        source: AgentSource? = nil,
        raw: Bool = false,
        messageLimit: Int? = nil,
        largeSessionByteThreshold: Int64? = Defaults.largeSessionByteThreshold,
        autoLargeSessionMessageLimit: Int = Defaults.autoLargeSessionMessageLimit,
        providers: [SessionProvider]
    ) {
        self.sessionID = sessionID
        self.source = source
        self.messageLimit = messageLimit
        self.largeSessionByteThreshold = largeSessionByteThreshold
        self.autoLargeSessionMessageLimit = autoLargeSessionMessageLimit
        formatter = ShowConversationFormatter(raw: raw)
        self.providers = providers
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

    /// Uses list summaries first for metadata-aware loading, then falls back to direct provider lookup.
    private func findLocatedSession() async throws -> LocatedSession? {
        logger.debug("Finding session", metadata: ["id": "\(sessionID)"])

        let candidateProviders = filteredProviders()

        let summaries = try await listSessions(from: candidateProviders)
        if let summary = matchingSummary(in: summaries) {
            return try await loadLocatedSession(from: summary, using: candidateProviders)
        }

        return try await loadFallbackSession(using: candidateProviders)
    }

    private func listSessions(from candidateProviders: [SessionProvider]) async throws -> [SessionSummary] {
        var all: [SessionSummary] = []
        for provider in candidateProviders {
            if let sessions = try? await provider.listSessions() {
                all.append(contentsOf: sessions)
            }
        }
        return all.sorted { $0.createdAt > $1.createdAt }
    }

    private func filteredProviders() -> [SessionProvider] {
        guard let source else { return providers }
        return providers.filter { $0.source == source }
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
        using candidateProviders: [SessionProvider]
    ) async throws -> LocatedSession? {
        let appliedLimit = resolvedMessageLimit(for: summary.byteSize)
        guard let provider = candidateProviders.first(where: { $0.source == summary.source }),
              let conversation = try? await provider.loadSession(
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

    private func loadFallbackSession(using candidateProviders: [SessionProvider]) async throws -> LocatedSession? {
        let fallbackLimit = resolvedMessageLimit(for: nil)
        for provider in candidateProviders {
            if let conversation = try? await provider.loadSession(id: sessionID, limit: fallbackLimit) {
                logger.info("🔍 Found session via exact fallback source=\(conversation.source.rawValue)")
                return makeLocatedSession(
                    conversation: conversation,
                    summary: nil,
                    appliedMessageLimit: fallbackLimit
                )
            }
        }
        return nil
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
