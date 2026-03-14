@testable import CTXMVKit
import Foundation
import Testing

/// Minimal helpers for unit-testing Codex parsing logic without a full rollout directory.
private enum CodexSessionReaderTestSupport {
    static func makeStatelessReader() -> CodexSessionReader {
        CodexSessionReader(fileSystem: MockFileManager())
    }

    static func decodeEntry(_ jsonl: String) -> CodexEntry? {
        makeStatelessReader().decodeLine(jsonl)
    }
}

@Suite("Verifies role extraction across modern and legacy Codex entry shapes.")
struct CodexRoleTests {
    struct TestCase: CustomTestStringConvertible, Sendable {
        let description: String
        let jsonl: String
        let expected: MessageRole?

        var testDescription: String { description }

        static let allCases: [TestCase] = [
            TestCase(
                description: "event_msg user_message → .user",
                jsonl: #"{"type":"event_msg","payload":{"type":"user_message","message":"hi"}}"#,
                expected: .user
            ),
            TestCase(
                description: "event_msg agent_message → .assistant",
                jsonl: #"{"type":"event_msg","payload":{"type":"agent_message","message":"done"}}"#,
                expected: .assistant
            ),
            TestCase(
                description: "response_item role=assistant → .assistant",
                jsonl: #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"done"}]}}"#,
                expected: .assistant
            ),
            TestCase(
                description: "response_item role=user → nil",
                jsonl: #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"question"}]}}"#,
                expected: nil
            ),
            TestCase(
                description: "response_item role=developer → nil",
                jsonl: #"{"type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"system"}]}}"#,
                expected: nil
            ),
            TestCase(
                description: "event_msg non-user → nil",
                jsonl: #"{"type":"event_msg","payload":{"type":"status_update"}}"#,
                expected: nil
            ),
        ]
    }

    @Test("identifies Codex message roles", arguments: TestCase.allCases)
    func extractRole(_ testCase: TestCase) {
        let reader = CodexSessionReaderTestSupport.makeStatelessReader()
        guard let entry = CodexSessionReaderTestSupport.decodeEntry(testCase.jsonl) else {
            Issue.record("Failed to decode JSONL: \(testCase.jsonl)")
            return
        }
        #expect(reader.extractRole(from: entry) == testCase.expected)
    }
}

@Suite("Verifies content extraction across supported Codex payload variants.")
struct CodexContentTests {
    struct TestCase: CustomTestStringConvertible, Sendable {
        let description: String
        let jsonl: String
        let expected: String

        var testDescription: String { description }

        static let allCases: [TestCase] = [
            TestCase(
                description: "event_msg payload.message",
                jsonl: #"{"type":"event_msg","payload":{"type":"user_message","message":"Hello"}}"#,
                expected: "Hello"
            ),
            TestCase(
                description: "response_item payload.content output_text block",
                jsonl: #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Response"}]}}"#,
                expected: "Response"
            ),
            TestCase(
                description: "response_item legacy item.content text block",
                jsonl: #"{"type":"response_item","item":{"content":[{"type":"text","text":"Direct"}]}}"#,
                expected: "Direct"
            ),
            TestCase(
                description: "unknown type → empty",
                jsonl: #"{"type":"session_start"}"#,
                expected: ""
            ),
        ]
    }

    @Test("extracts Codex message content", arguments: TestCase.allCases)
    func extractContent(_ testCase: TestCase) {
        let reader = CodexSessionReaderTestSupport.makeStatelessReader()
        guard let entry = CodexSessionReaderTestSupport.decodeEntry(testCase.jsonl) else {
            Issue.record("Failed to decode JSONL: \(testCase.jsonl)")
            return
        }
        #expect(reader.extractContent(from: entry) == testCase.expected)
    }
}

@Suite("Verifies rollout-file discovery against naming rules and nested directories.")
struct CodexRolloutTests {
    @Test("filters by rollout- prefix and .jsonl extension")
    func filterFiles() throws {
        let fileSystem = MockFileManager()
        let base = URL(fileURLWithPath: "/mock/sessions")
        let rollout = base.appendingPathComponent("rollout-1.jsonl")
        let notRollout = base.appendingPathComponent("other.jsonl")
        let notJsonl = base.appendingPathComponent("rollout-2.txt")

        fileSystem.directories[base.path] = [rollout, notRollout, notJsonl]
        fileSystem.files[rollout.path] = Data()
        fileSystem.files[notRollout.path] = Data()
        fileSystem.files[notJsonl.path] = Data()

        let reader = CodexSessionReader(fileSystem: fileSystem, baseDir: base)
        let found = try reader.findRolloutFiles(in: base)

        #expect(found.count == 1)
        #expect(found[0].lastPathComponent == "rollout-1.jsonl")
    }
}

@Suite("Exercises Codex session listing and loading against mock rollout files.")
struct CodexSessionTests {
    /// Shared rollout fixture rooted under a fake `.codex/sessions` subtree.
    private struct Fixture {
        let fileSystem = MockFileManager()
        let baseDir = URL(fileURLWithPath: "/mock/codex/sessions")
        let subdirectoryName = "sub1"

        var subdirectory: URL { baseDir.appendingPathComponent(subdirectoryName) }

        func rolloutFile(named fileName: String) -> URL {
            subdirectory.appendingPathComponent(fileName)
        }

        /// Writes a rollout file into the nested directory expected by `findRolloutFiles`.
        mutating func configureRollout(
            named fileName: String,
            jsonl: String = TestFixtures.codexJSONL()
        ) -> URL {
            let rollout = rolloutFile(named: fileName)
            fileSystem.directories[baseDir.path] = [subdirectory]
            fileSystem.directories[subdirectory.path] = [rollout]
            fileSystem.files[rollout.path] = Data(jsonl.utf8)
            return rollout
        }

        func makeReader() -> CodexSessionReader {
            CodexSessionReader(fileSystem: fileSystem, baseDir: baseDir)
        }
    }

    @Test("listSessions returns empty when base dir missing")
    func listEmpty() async throws {
        let fileSystem = MockFileManager()
        let reader = CodexSessionReader(fileSystem: fileSystem, baseDir: URL(fileURLWithPath: "/nonexistent"))
        #expect(try await reader.listSessions().isEmpty)
    }

    @Test("listSessions finds rollout files and extracts metadata")
    func listFinds() async throws {
        var fixture = Fixture()
        _ = fixture.configureRollout(named: "rollout-abc.jsonl")
        let sessions = try await fixture.makeReader().listSessions()

        #expect(sessions.count == 1)
        #expect(sessions[0].id == "codex-session-1")
        #expect(sessions[0].source == .codex)
        #expect(sessions[0].lastUserMessage == "Add tests")
    }

    @Test("listSessions skips system noise and uses first meaningful user message")
    func listSkipsNoise() async throws {
        var fixture = Fixture()
        _ = fixture.configureRollout(
            named: "rollout-noise.jsonl",
            jsonl: TestFixtures.codexJSONLWithNoiseFirst()
        )
        let sessions = try await fixture.makeReader().listSessions()

        #expect(sessions.count == 1)
        #expect(sessions[0].lastUserMessage == "Fix the bug")
    }

    @Test("loadSession parses user and assistant messages")
    func loadParses() async throws {
        var fixture = Fixture()
        _ = fixture.configureRollout(named: "rollout-abc.jsonl")
        let conversation = try await fixture.makeReader().loadSession(id: "codex-session-1")

        #expect(conversation != nil)
        let msgs = conversation!.messages
        #expect(msgs.count == 4)
        #expect(msgs[0].role == .user)
        #expect(msgs[0].content == "Build a function")
        #expect(msgs[1].role == .assistant)
        #expect(msgs[1].content == "Sure, here is the function.")
        #expect(msgs[2].role == .user)
        #expect(msgs[2].content == "Add tests")
        #expect(msgs[3].role == .assistant)
        #expect(msgs[3].content == "Done! Tests added.")
    }

    @Test("loadSession limit returns only the most recent messages")
    func loadParsesWithLimit() async throws {
        var fixture = Fixture()
        _ = fixture.configureRollout(named: "rollout-abc.jsonl")
        let conversation = try await fixture.makeReader().loadSession(id: "codex-session-1", limit: 2)

        #expect(conversation != nil)
        let msgs = conversation!.messages
        #expect(msgs.count == 2)
        #expect(msgs[0].role == .user)
        #expect(msgs[0].content == "Add tests")
        #expect(msgs[1].role == .assistant)
        #expect(msgs[1].content == "Done! Tests added.")
    }

    @Test("loadSession finds sessions when session_meta is not on the first line")
    func loadWithDelayedSessionMeta() async throws {
        let fileSystem = MockFileManager()
        let base = URL(fileURLWithPath: "/mock/codex/sessions")
        let subdir = base.appendingPathComponent("sub1")
        let rollout = subdir.appendingPathComponent(
            "rollout-2026-03-14-4248e42d-6278-4e38-913b-f7a3ae075812.jsonl"
        )

        fileSystem.directories[base.path] = [subdir]
        fileSystem.directories[subdir.path] = [rollout]
        fileSystem.files[rollout.path] = TestFixtures.codexJSONLWithDelayedSessionMeta(
            sessionId: "4248e42d-6278-4e38-913b-f7a3ae075812"
        ).data(using: .utf8)!

        let reader = CodexSessionReader(fileSystem: fileSystem, baseDir: base)
        let conversation = try await reader.loadSession(
            id: "4248e42d-6278-4e38-913b-f7a3ae075812"
        )

        #expect(conversation != nil)
        #expect(conversation?.id == "4248e42d-6278-4e38-913b-f7a3ae075812")
        #expect(conversation?.messages.first?.role == .user)
    }

    @Test("loadSession returns nil for unknown ID")
    func loadNotFound() async throws {
        let fixture = Fixture()
        #expect(try await fixture.makeReader().loadSession(id: "nope") == nil)
    }
}
