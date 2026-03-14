import Foundation

/// A message extracted from a Cursor SQLite blob.
/// Top-level structure: `{role, content, id?, providerOptions?}`
struct CursorBlobMessage: Codable, Sendable {
    let role: String
    let content: TextOrBlocks
    let id: String?

    /// Ignore providerOptions and any other unknown keys.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(String.self, forKey: .role)
        id = try container.decodeIfPresent(String.self, forKey: .id)

        if let str = try? container.decode(String.self, forKey: .content) {
            content = .text(str)
        } else if let blocks = try? container.decode([ContentBlock].self, forKey: .content) {
            content = .blocks(blocks)
        } else {
            content = .text("")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case role, content, id
    }
}

/// Top-level entry in Cursor agent-transcripts JSONL files.
struct CursorAgentTranscriptEntry: Codable, Sendable {
    let role: String?
    let timestamp: String?
    let message: CursorAgentTranscriptMessage?

    init(role: String? = nil, timestamp: String? = nil, message: CursorAgentTranscriptMessage? = nil) {
        self.role = role
        self.timestamp = timestamp
        self.message = message
    }
}

/// Represents the nested `message` payload in a Cursor transcript entry.
struct CursorAgentTranscriptMessage: Codable, Sendable {
    let role: String?
    let content: TextOrBlocks?

    init(role: String? = nil, content: TextOrBlocks? = nil) {
        self.role = role
        self.content = content
    }
}
