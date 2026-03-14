@testable import CTXMVKit
import Foundation
import Testing

/// Minimal helpers for unit-testing pure Claude provider parsing logic without real files.
private enum ClaudeCodeSessionReaderTestSupport {
    static func makeStatelessReader() -> ClaudeCodeSessionReader {
        ClaudeCodeSessionReader(fileSystem: MockFileManager())
    }

    static func decodeEntry(_ jsonl: String) -> ClaudeCodeEntry? {
        makeStatelessReader().decodeLine(jsonl)
    }
}

@Suite("Covers encoded project path decoding in Claude Code storage paths.")
struct DecodeProjectPathTests {
    struct TestCase: CustomTestStringConvertible, Sendable {
        let description: String
        let input: String
        let expected: String?

        var testDescription: String { description }

        static let allCases: [TestCase] = [
            TestCase(description: "standard encoded path", input: "-Users-example-workspace-foo", expected: "/Users/example/workspace/foo"),
            TestCase(description: "single component", input: "-tmp", expected: "/tmp"),
            TestCase(description: "deep path", input: "-a-b-c-d-e", expected: "/a/b/c/d/e"),
            TestCase(description: "no leading dash returns nil", input: "Users-example", expected: nil),
            TestCase(description: "empty string returns nil", input: "", expected: nil),
        ]
    }

    @Test("decodes encoded-cwd to file path", arguments: TestCase.allCases)
    func decode(_ testCase: TestCase) {
        #expect(ClaudeCodeSessionReader.decodeProjectPath(testCase.input) == testCase.expected)
    }
}

@Suite("Verifies role inference from Claude Code JSONL entries.")
struct ClaudeCodeRoleTests {
    struct TestCase: CustomTestStringConvertible, Sendable {
        let description: String
        let jsonl: String
        let expected: MessageRole?

        var testDescription: String { description }

        static let allCases: [TestCase] = [
            TestCase(
                description: "type user → .user",
                jsonl: #"{"type":"user","message":{"role":"user","content":"hi"}}"#,
                expected: .user
            ),
            TestCase(
                description: "message.role assistant → .assistant",
                jsonl: #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hey"}]}}"#,
                expected: .assistant
            ),
            TestCase(
                description: "type progress → nil",
                jsonl: #"{"type":"progress"}"#,
                expected: nil
            ),
            TestCase(
                description: "type system → nil",
                jsonl: #"{"type":"system"}"#,
                expected: nil
            ),
        ]
    }

    @Test("identifies message roles", arguments: TestCase.allCases)
    func extractRole(_ testCase: TestCase) {
        let reader = ClaudeCodeSessionReaderTestSupport.makeStatelessReader()
        guard let entry = ClaudeCodeSessionReaderTestSupport.decodeEntry(testCase.jsonl) else {
            #expect(testCase.expected == nil)
            return
        }
        #expect(reader.extractRole(from: entry) == testCase.expected)
    }
}

@Suite("Verifies text extraction from Claude Code JSONL entries.")
struct ClaudeCodeContentTests {
    struct TestCase: CustomTestStringConvertible, Sendable {
        let description: String
        let jsonl: String
        let expected: String

        var testDescription: String { description }

        static let allCases: [TestCase] = [
            TestCase(
                description: "string content",
                jsonl: #"{"type":"user","message":{"content":"Hello"}}"#,
                expected: "Hello"
            ),
            TestCase(
                description: "array content with text blocks",
                jsonl: #"{"type":"assistant","message":{"content":[{"type":"text","text":"Part 1"},{"type":"tool_use"},{"type":"text","text":"Part 2"}]}}"#,
                expected: "Part 1\nPart 2"
            ),
            TestCase(
                description: "no message key → empty",
                jsonl: #"{"type":"progress"}"#,
                expected: ""
            ),
            TestCase(
                description: "empty message → empty",
                jsonl: #"{"type":"user","message":{}}"#,
                expected: ""
            ),
        ]
    }

    @Test("extracts text content", arguments: TestCase.allCases)
    func extractContent(_ testCase: TestCase) {
        let reader = ClaudeCodeSessionReaderTestSupport.makeStatelessReader()
        guard let entry = ClaudeCodeSessionReaderTestSupport.decodeEntry(testCase.jsonl) else {
            #expect(testCase.expected == "")
            return
        }
        #expect(reader.extractContent(from: entry) == testCase.expected)
    }
}

@Suite("Verifies which Claude Code entry types are skipped as non-message data.")
struct ClaudeCodeSkipTests {
    struct TestCase: CustomTestStringConvertible, Sendable {
        let description: String
        let jsonl: String
        let expected: Bool

        var testDescription: String { description }

        static let allCases: [TestCase] = [
            TestCase(description: "progress → skip", jsonl: #"{"type":"progress"}"#, expected: true),
            TestCase(description: "file-history-snapshot → skip", jsonl: #"{"type":"file-history-snapshot"}"#, expected: true),
            TestCase(description: "user → keep", jsonl: #"{"type":"user"}"#, expected: false),
            TestCase(description: "assistant → keep", jsonl: #"{"type":"assistant","message":{"role":"assistant"}}"#, expected: false),
        ]
    }

    @Test("filters non-message entry types", arguments: TestCase.allCases)
    func shouldSkip(_ testCase: TestCase) {
        let reader = ClaudeCodeSessionReaderTestSupport.makeStatelessReader()
        guard let entry = ClaudeCodeSessionReaderTestSupport.decodeEntry(testCase.jsonl) else {
            Issue.record("Failed to decode JSONL: \(testCase.jsonl)")
            return
        }
        #expect(reader.shouldSkipEntry(entry) == testCase.expected)
    }
}

@Suite("Exercises Claude Code session listing and loading against mock storage.")
struct ClaudeCodeSessionTests {
    /// Shared file fixture that mirrors Claude Code's on-disk project/session hierarchy.
    private struct Fixture {
        let fileSystem = MockFileManager()
        let baseDir = URL(fileURLWithPath: "/mock/claude/projects")
        let encodedProjectDirectory = "-Users-example-test"
        let sessionID = "session-abc"

        var projectDir: URL { baseDir.appendingPathComponent(encodedProjectDirectory) }
        var sessionFile: URL { projectDir.appendingPathComponent("\(sessionID).jsonl") }

        /// Writes one JSONL session into the encoded project directory.
        mutating func configureSession(jsonl: String = TestFixtures.claudeCodeJSONL()) {
            fileSystem.directories[baseDir.path] = [projectDir]
            fileSystem.directories[projectDir.path] = [sessionFile]
            fileSystem.files[sessionFile.path] = Data(jsonl.utf8)
        }

        func makeReader() -> ClaudeCodeSessionReader {
            ClaudeCodeSessionReader(fileSystem: fileSystem, baseDir: baseDir)
        }
    }

    @Test("listSessions returns empty when base dir missing")
    func listEmpty() async throws {
        let fileSystem = MockFileManager()
        let reader = ClaudeCodeSessionReader(fileSystem: fileSystem, baseDir: URL(fileURLWithPath: "/nonexistent"))
        #expect(try await reader.listSessions().isEmpty)
    }

    @Test("listSessions finds sessions in project directories")
    func listFinds() async throws {
        var fixture = Fixture()
        fixture.configureSession()
        let sessions = try await fixture.makeReader().listSessions()

        #expect(sessions.count == 1)
        #expect(sessions[0].id == fixture.sessionID)
        #expect(sessions[0].source == .claudeCode)
        #expect(sessions[0].projectPath == "/Users/example/test")
        #expect(sessions[0].lastUserMessage == "Thanks")
    }

    @Test("loadSession returns nil for unknown ID")
    func loadNotFound() async throws {
        let fixture = Fixture()
        #expect(try await fixture.makeReader().loadSession(id: "nope") == nil)
    }

    @Test("loadSession parses user and assistant messages, skips progress/snapshot")
    func loadParsesMessages() async throws {
        var fixture = Fixture()
        fixture.configureSession()
        let conversation = try await fixture.makeReader().loadSession(id: fixture.sessionID)

        #expect(conversation != nil)
        let messages = conversation!.messages
        #expect(messages.count == 4)
        #expect(messages[0] == .init(role: .user, content: "Hello world", timestamp: messages[0].timestamp))
        #expect(messages[1] == .init(role: .assistant, content: "Hi! How can I help?", timestamp: messages[1].timestamp))
        #expect(messages[2] == .init(role: .user, content: "Thanks", timestamp: messages[2].timestamp))
        #expect(messages[3] == .init(role: .assistant, content: "You're welcome!", timestamp: messages[3].timestamp))
    }

    @Test("loadSession limit returns only the most recent messages")
    func loadParsesMessagesWithLimit() async throws {
        var fixture = Fixture()
        fixture.configureSession()
        let conversation = try await fixture.makeReader().loadSession(id: fixture.sessionID, limit: 2)

        #expect(conversation != nil)
        let messages = conversation!.messages
        #expect(messages.count == 2)
        #expect(messages[0].role == .user)
        #expect(messages[0].content == "Thanks")
        #expect(messages[1].role == .assistant)
        #expect(messages[1].content == "You're welcome!")
    }
}
