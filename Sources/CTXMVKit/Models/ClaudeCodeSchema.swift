import Foundation

/// Enumerates top-level Claude Code JSONL entry kinds.
enum ClaudeCodeEntryType: String, Codable, Sendable {
    case user
    case assistant
    case progress
    case system
    case fileHistorySnapshot = "file-history-snapshot"
}

/// Enumerates message roles used inside Claude Code message payloads.
enum ClaudeCodeMessageRole: String, Codable, Sendable {
    case user
    case assistant
    case system
    case tool
}

/// Top-level entry in a Claude Code JSONL session file.
/// Each line is one of: user message, assistant message, progress, system, file-history-snapshot, etc.
/// - Note: `isSidechain` is true for claude-mem observer sessions (monitoring another session).
struct ClaudeCodeEntry: Codable, Sendable {
    let type: String
    let sessionId: String?
    let timestamp: String?
    let uuid: String?
    let parentUuid: String?
    let version: String?
    let cwd: String?
    let gitBranch: String?
    let model: String?
    let message: ClaudeCodeMessage?
    let isSidechain: Bool?

    init(
        type: String, sessionId: String? = nil, timestamp: String? = nil,
        uuid: String? = nil, parentUuid: String? = nil, version: String? = nil,
        cwd: String? = nil, gitBranch: String? = nil, model: String? = nil,
        message: ClaudeCodeMessage? = nil, isSidechain: Bool? = nil
    ) {
        self.type = type; self.sessionId = sessionId; self.timestamp = timestamp
        self.uuid = uuid; self.parentUuid = parentUuid; self.version = version
        self.cwd = cwd; self.gitBranch = gitBranch; self.model = model
        self.message = message; self.isSidechain = isSidechain
    }

    var entryType: ClaudeCodeEntryType? {
        ClaudeCodeEntryType(rawValue: type)
    }
}

/// The `message` field inside a Claude Code JSONL entry.
struct ClaudeCodeMessage: Codable, Sendable {
    let role: String?
    let content: TextOrBlocks?
    let model: String?
    let stop_reason: String?
    let stop_sequence: String?

    init(
        role: String? = nil, content: TextOrBlocks? = nil,
        model: String? = nil, stop_reason: String? = nil, stop_sequence: String? = nil
    ) {
        self.role = role; self.content = content; self.model = model
        self.stop_reason = stop_reason; self.stop_sequence = stop_sequence
    }

    var messageRole: ClaudeCodeMessageRole? {
        role.flatMap(ClaudeCodeMessageRole.init(rawValue:))
    }
}
