import Foundation

/// Writes Cursor transcript JSONL files used by transcript-based fallback loading.
struct CursorTranscriptWriter: Sendable {
    private let fileSystem: FileSystemProtocol

    init(fileSystem: FileSystemProtocol) {
        self.fileSystem = fileSystem
    }

    func write(_ conversation: UnifiedConversation, to transcriptFile: URL) throws {
        try createTranscriptDirectory(for: transcriptFile)
        let data = try transcriptData(for: conversation)

        guard fileSystem.createFile(atPath: transcriptFile.path, contents: data, attributes: nil) else {
            throw MigrationError.writeFailed("Failed to create transcript file at \(transcriptFile.path)")
        }
    }

    private func createTranscriptDirectory(for transcriptFile: URL) throws {
        try fileSystem.createDirectory(
            at: transcriptFile.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    private func transcriptData(for conversation: UnifiedConversation) throws -> Data {
        let content = transcriptContent(for: conversation)
        guard let data = content.data(using: .utf8) else {
            throw MigrationError.writeFailed("Failed to encode transcript file as UTF-8")
        }
        return data
    }

    private func transcriptContent(for conversation: UnifiedConversation) -> String {
        let lines = conversation.messages.compactMap { message in
            transcriptLine(for: message, source: conversation.source)
        }
        return lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }

    private func transcriptLine(for message: UnifiedMessage, source: AgentSource) -> String? {
        guard isTranscriptMessage(message) else {
            return nil
        }

        let entry = transcriptEntry(for: message, source: source)
        guard let data = try? MigratorUtils.jsonEncoder.encode(entry) else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    /// Wraps a normalized message in Cursor's transcript entry schema.
    private func transcriptEntry(for message: UnifiedMessage, source: AgentSource) -> CursorAgentTranscriptEntry {
        let body = message.decodedContent(for: source)
        return CursorAgentTranscriptEntry(
            role: message.role.rawValue,
            timestamp: message.timestamp.map(MigratorUtils.isoFormatter.string(from:)),
            message: CursorAgentTranscriptMessage(
                role: message.role.rawValue,
                content: .blocks([ContentBlock(type: .text, text: transcriptText(for: message.role, body: body))])
            )
        )
    }

    /// Cursor stores user prompts inside `<user_query>` wrappers so later parsing can identify them.
    private func transcriptText(for role: MessageRole, body: String) -> String {
        role == .user ? CursorAgentTag.userQuery.wrap(body) : body
    }

    /// Cursor transcripts only persist conversational turns; system/tool messages are not replayed.
    private func isTranscriptMessage(_ message: UnifiedMessage) -> Bool {
        message.role == .user || message.role == .assistant
    }
}
