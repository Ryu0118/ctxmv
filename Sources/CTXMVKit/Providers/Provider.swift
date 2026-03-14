import Foundation

/// Loads session summaries and conversations from one agent-specific backing store.
package protocol SessionProvider: Sendable {
    var source: AgentSource { get }

    /// Returns all available sessions as summaries.
    func listSessions() async throws -> [SessionSummary]

    /// Returns the session matching `id`, optionally using a known storage path and message limit.
    func loadSession(id: String, storagePath: String?, limit: Int?) async throws -> UnifiedConversation?
}

package extension SessionProvider {
    /// Convenience overload for callers that do not know the storage path or message limit.
    func loadSession(id: String) async throws -> UnifiedConversation? {
        try await loadSession(id: id, storagePath: nil, limit: nil)
    }

    /// Convenience overload for callers that only want to supply a message limit.
    func loadSession(id: String, limit: Int?) async throws -> UnifiedConversation? {
        try await loadSession(id: id, storagePath: nil, limit: limit)
    }

    /// Convenience overload for callers that already know the backing storage path.
    func loadSession(id: String, storagePath: String?) async throws -> UnifiedConversation? {
        try await loadSession(id: id, storagePath: storagePath, limit: nil)
    }
}
