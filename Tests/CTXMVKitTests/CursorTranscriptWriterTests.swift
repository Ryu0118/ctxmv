@testable import CTXMVKit
import Foundation
import Testing

struct CursorTranscriptWriterTests {
    @Test("write serializes user and assistant messages as Cursor transcript JSONL")
    func writeTranscript() throws {
        let fileSystem = MockFileManager()
        let writer = CursorTranscriptWriter(fileSystem: fileSystem)
        let transcriptFile = URL(fileURLWithPath: "/tmp/agent-transcripts/session.jsonl")
        let timestamp = TestFixtures.sampleDate
        let conversation = UnifiedConversation(
            id: "cursor-session",
            source: .cursor,
            projectPath: "/tmp/project",
            createdAt: timestamp,
            model: "gpt-test",
            messages: [
                UnifiedMessage(role: .system, content: "ignore me", timestamp: timestamp),
                UnifiedMessage(role: .user, content: CursorAgentTag.userQuery.wrap("hello"), timestamp: timestamp),
                UnifiedMessage(role: .assistant, content: "hi", timestamp: timestamp),
            ]
        )

        try writer.write(conversation, to: transcriptFile)

        let directoryPath = transcriptFile.deletingLastPathComponent().path
        #expect(fileSystem.directories[directoryPath] != nil)

        let written = try #require(fileSystem.files[transcriptFile.path])
        let content = try #require(String(data: written, encoding: .utf8))
        let lines = content.split(separator: "\n").map(String.init)

        // Only user/assistant turns are persisted into transcript JSONL.
        #expect(lines.count == 2)

        let userEntry = try #require(decodeTranscriptEntry(from: lines[0]))
        #expect(userEntry.role == MessageRole.user.rawValue)
        #expect(userEntry.message?.content?.textContent == CursorAgentTag.userQuery.wrap("hello"))

        let assistantEntry = try #require(decodeTranscriptEntry(from: lines[1]))
        #expect(assistantEntry.role == MessageRole.assistant.rawValue)
        #expect(assistantEntry.message?.content?.textContent == "hi")
    }

    /// Decodes one serialized transcript line for schema assertions.
    private func decodeTranscriptEntry(from line: String) -> CursorAgentTranscriptEntry? {
        guard let data = line.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(CursorAgentTranscriptEntry.self, from: data)
    }
}
