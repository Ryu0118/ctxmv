import Foundation

/// Identifies the agent that produced or consumes a session.
package enum AgentSource: String, Codable, CaseIterable, Sendable {
    case claudeCode = "claude-code"
    case codex
    case cursor
}

/// Describes the speaker for a unified message.
enum MessageRole: String, Codable, Sendable {
    case user
    case assistant
    case system
    case tool
}

/// A normalized chat message shared across agent-specific schemas.
struct UnifiedMessage: Codable, Sendable, Equatable {
    let role: MessageRole
    let content: String
    let timestamp: Date?

    init(role: MessageRole, content: String, timestamp: Date?) {
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
}

/// A normalized conversation that can be listed, shown, or migrated.
package struct UnifiedConversation: Codable, Sendable {
    let id: String
    let source: AgentSource
    let projectPath: String?
    let createdAt: Date
    let model: String?
    let messages: [UnifiedMessage]
    /// True when this is a claude-mem observer session (monitoring another session).
    let isObserverSession: Bool

    init(
        id: String,
        source: AgentSource,
        projectPath: String?,
        createdAt: Date,
        model: String?,
        messages: [UnifiedMessage],
        isObserverSession: Bool = false
    ) {
        self.id = id
        self.source = source
        self.projectPath = projectPath
        self.createdAt = createdAt
        self.model = model
        self.messages = messages
        self.isObserverSession = isObserverSession
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        source = try container.decode(AgentSource.self, forKey: .source)
        projectPath = try container.decodeIfPresent(String.self, forKey: .projectPath)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        messages = try container.decode([UnifiedMessage].self, forKey: .messages)
        isObserverSession = try container.decodeIfPresent(Bool.self, forKey: .isObserverSession) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case id, source, projectPath, createdAt, model, messages, isObserverSession
    }
}

extension UnifiedMessage {
    /// Returns the content decoded for the originating agent format.
    func decodedContent(for source: AgentSource) -> String {
        switch source {
        case .claudeCode:
            return ClaudeCodeContentDecoder.decode(content)
        case .cursor:
            return CursorAgentContentDecoder.decode(content)
        case .codex:
            return content
        }
    }
}

extension String {
    /// Returns `self` truncated to `maxLength`, appending `...` when needed.
    func truncated(to maxLength: Int) -> String {
        guard count > maxLength else { return self }
        return String(prefix(maxLength - 3)) + "..."
    }

    /// Returns a path shortened in the middle while preserving the leading root and final component.
    func pathTruncated(to maxLength: Int) -> String {
        guard count > maxLength else { return self }
        let parts = split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count > 2 else { return truncated(to: maxLength) }

        let ellipsis = "..."
        let trailing = parts.suffix(1).joined(separator: "/")

        // Try progressively fewer leading components
        for headComponentCount in stride(from: parts.count - 1, through: 1, by: -1) {
            let head = parts.prefix(headComponentCount).joined(separator: "/")
            let candidate = "/" + head + "/" + ellipsis + "/" + trailing
            if candidate.count <= maxLength {
                return candidate
            }
        }

        // Fallback: just ellipsis + trailing
        let minimal = ellipsis + "/" + trailing
        if minimal.count <= maxLength {
            return minimal
        }
        return truncated(to: maxLength)
    }
}

/// Describes a session without loading its full message history.
package struct SessionSummary: Sendable {
    let id: String
    let source: AgentSource
    let projectPath: String?
    let createdAt: Date
    /// Timestamp of the last message in the session. Used for sorting by recent activity.
    let lastMessageAt: Date?
    let model: String?
    let messageCount: Int
    let lastUserMessage: String?
    let byteSize: Int64?
    /// True when this is a claude-mem observer session (monitoring another session).
    let isObserverSession: Bool
    /// Optional path to the agent's backing storage for direct loading when ID lookup fails.
    let storagePath: String?

    init(
        id: String,
        source: AgentSource,
        projectPath: String?,
        createdAt: Date,
        lastMessageAt: Date? = nil,
        model: String?,
        messageCount: Int,
        lastUserMessage: String?,
        byteSize: Int64? = nil,
        isObserverSession: Bool = false,
        storagePath: String? = nil
    ) {
        self.id = id
        self.source = source
        self.projectPath = projectPath
        self.createdAt = createdAt
        self.lastMessageAt = lastMessageAt
        self.model = model
        self.messageCount = messageCount
        self.lastUserMessage = lastUserMessage
        self.byteSize = byteSize
        self.isObserverSession = isObserverSession
        self.storagePath = storagePath
    }
}

package extension Int64 {
    /// Returns a human-readable byte count such as `512 B` or `1.2 MB`.
    func formattedByteCount() -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(self)
        var unitIndex = 0

        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }

        let number: String
        if unitIndex == 0 || value >= 10 {
            number = "\(Int(value.rounded()))"
        } else {
            number = String(format: "%.1f", value)
        }

        return "\(number) \(units[unitIndex])"
    }
}
