@testable import CTXMVKit
import Foundation
import Testing

struct CursorBlobTests {
    struct TestCase: CustomTestStringConvertible {
        let description: String
        let data: Data
        let expectedRole: MessageRole?
        let expectedContent: String?

        var testDescription: String {
            description
        }

        private static let multiBlockAssistantJSON =
            // swiftlint:disable:next line_length
            #"{"role":"assistant","content":[{"type":"text","text":"Line 1"},{"type":"tool_use","name":"bash"},{"type":"text","text":"Line 2"}]}"#

        static let allCases: [TestCase] = [
            TestCase(
                description: "raw JSON user message",
                data: Data(#"{"role":"user","content":[{"type":"text","text":"Hello from cursor"}]}"#.utf8),
                expectedRole: .user,
                expectedContent: "Hello from cursor"
            ),
            TestCase(
                description: "raw JSON assistant message",
                data: Data(#"{"role":"assistant","content":[{"type":"text","text":"Here is the answer"}]}"#.utf8),
                expectedRole: .assistant,
                expectedContent: "Here is the answer"
            ),
            TestCase(
                description: "raw JSON multiple text blocks",
                data: Data(Self.multiBlockAssistantJSON.utf8),
                expectedRole: .assistant,
                expectedContent: "Line 1\nLine 2"
            ),
            TestCase(
                description: "raw JSON tool role → skip",
                data: Data(#"{"role":"tool","content":[{"type":"tool-result","text":"ok"}]}"#.utf8),
                expectedRole: nil,
                expectedContent: nil
            ),
            TestCase(
                description: "raw JSON system role → skip",
                data: Data(#"{"role":"system","content":[{"type":"text","text":"system prompt"}]}"#.utf8),
                expectedRole: nil,
                expectedContent: nil
            ),
            TestCase(
                description: "raw JSON no text blocks → skip",
                data: Data(#"{"role":"assistant","content":[{"type":"tool_use","name":"bash"}]}"#.utf8),
                expectedRole: nil,
                expectedContent: nil
            ),
            TestCase(
                description: "protobuf-wrapped assistant message",
                data: Data([0x0A, 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0x22, 0xFF])
                    + Data(#"{"id":"1","role":"assistant","content":[{"type":"text","text":"Protobuf answer"}]}"#.utf8)
                    + Data([0x00, 0x01, 0x02]),
                expectedRole: .assistant,
                expectedContent: "Protobuf answer"
            ),
            TestCase(
                description: "protobuf with no JSON → nil",
                data: Data([0x0A, 0x05, 0x68, 0x65, 0x6C, 0x6C, 0x6F]),
                expectedRole: nil,
                expectedContent: nil
            ),
            TestCase(
                description: "empty data → nil",
                data: Data(),
                expectedRole: nil,
                expectedContent: nil
            ),
        ]
    }

    @Test("extracts messages from blob data", arguments: TestCase.allCases)
    func extractMessage(_ testCase: TestCase) {
        let message = CursorBlobParser.extractMessage(from: testCase.data)

        #expect(message?.role == testCase.expectedRole)
        #expect(message?.content == testCase.expectedContent)
    }
}

struct CursorDedupTests {
    @Test("conversation(fromDatabaseAt:) deduplicates identical messages from raw and protobuf blobs")
    func dedup() throws {
        let sqlite = MockSQLiteReader()

        let rawJSON = Data(#"{"role":"user","content":[{"type":"text","text":"Hello"}]}"#.utf8)
        var protobuf = Data([0x0A, 0x22, 0x33])
        protobuf.append(rawJSON)
        let metadataJSON = #"{"agentId":"test","name":"Test","createdAt":1710000000000,"lastUsedModel":"gpt-4"}"#

        sqlite.blobResults = [
            (id: "blob1", data: rawJSON),
            (id: "blob2", data: protobuf),
        ]
        sqlite.queryResults = [[
            "key": "composerData",
            "value": metadataJSON.utf8.map { String(format: "%02x", $0) }.joined(),
        ]]

        let reader = CursorSessionReader(fileSystem: MockFileManager(), sqlite: sqlite)
        let metadata = try #require(try reader.readMetadata(fromDatabaseAt: "/fake.db"))

        let conversation = try reader.conversation(
            fromDatabaseAt: "/fake.db",
            metadata: metadata,
            limit: nil
        )

        #expect(conversation.messages.count == 1)
        #expect(conversation.messages[0].content == "Hello")
    }
}

struct HexDecodeTests {
    struct TestCase: CustomTestStringConvertible {
        let description: String
        let input: String
        let expected: Data?

        var testDescription: String {
            description
        }

        static let allCases: [TestCase] = [
            TestCase(description: "valid ASCII hex", input: "48656c6c6f", expected: Data("Hello".utf8)),
            TestCase(description: "empty string", input: "", expected: Data()),
            TestCase(description: "invalid hex chars", input: "ZZZZ", expected: nil),
            TestCase(description: "odd length hex", input: "ABC", expected: nil),
        ]
    }

    @Test("converts hex strings", arguments: TestCase.allCases)
    func hexDecode(_ testCase: TestCase) {
        #expect(CursorBlobParser.hexDecode(testCase.input) == testCase.expected)
    }
}

struct CursorSessionTests {
    /// Shared test fixture for Cursor transcript/database layouts.
    private struct Fixture {
        let fileSystem = MockFileManager()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let sessionID = "c9f05d75-b958-42cf-932b-b081a8229174"
        let workspaceHash = "ab977e03128add0e997cf16fa9d262a5"

        let genericProjectPath = "/Users/tester/workspaces/sample-project"
        let legacyProjectPath = "/Users/tester/workspaces/library/example"

        var chatsRoot: URL {
            home.appendingPathComponent(".cursor/chats")
        }

        var projectsRoot: URL {
            home.appendingPathComponent(".cursor/projects")
        }

        var helperSkillFile: URL {
            home.appendingPathComponent(".agent/skills/generic-helper/SKILL.md")
        }

        /// Mimics the legacy flat `agent-transcripts/<session>.jsonl` layout.
        mutating func configureLegacyTranscriptSession() -> URL {
            let workspace = projectsRoot.appendingPathComponent("Users-tester-workspaces-library-example")
            let transcriptDirectory = workspace.appendingPathComponent("agent-transcripts")
            let transcriptFile = transcriptDirectory
                .appendingPathComponent("87245085-1456-4f87-a575-4a85b759cd1d.jsonl")

            fileSystem.directories[projectsRoot.path] = [workspace]
            fileSystem.directories[workspace.path] = [transcriptDirectory]
            fileSystem.directories[transcriptDirectory.path] = [transcriptFile]
            fileSystem.files[transcriptFile.path] = Data(TestFixtures.cursorTranscriptJSONL().utf8)

            return transcriptFile
        }

        /// Mimics the nested `agent-transcripts/<session>/<session>.jsonl` layout with project hints.
        mutating func configureNestedTranscriptSession() -> URL {
            let workspace = projectsRoot.appendingPathComponent("Users-tester-workspaces-sample-project")
            let transcriptDirectory = workspace.appendingPathComponent("agent-transcripts")
            let sessionDirectory = transcriptDirectory.appendingPathComponent(sessionID)
            let transcriptFile = sessionDirectory.appendingPathComponent("\(sessionID).jsonl")
            let packageJSON = URL(fileURLWithPath: genericProjectPath).appendingPathComponent("package.json")
            let sourceFile = URL(fileURLWithPath: genericProjectPath).appendingPathComponent("src/index.ts")

            fileSystem.directories[home.path] = [home.appendingPathComponent(".cursor")]
            fileSystem.directories[projectsRoot.path] = [workspace]
            fileSystem.directories[workspace.path] = [transcriptDirectory]
            fileSystem.directories[transcriptDirectory.path] = [sessionDirectory]
            fileSystem.directories[sessionDirectory.path] = [transcriptFile]
            fileSystem.directories[genericProjectPath] = [
                packageJSON.deletingLastPathComponent(),
                sourceFile.deletingLastPathComponent(),
            ]
            fileSystem
                .directories[URL(fileURLWithPath: genericProjectPath).appendingPathComponent("src").path] = [sourceFile]

            fileSystem.files[helperSkillFile.path] = Data("skill".utf8)
            fileSystem.files[packageJSON.path] = Data("{}".utf8)
            fileSystem.files[sourceFile.path] = Data("export {}".utf8)
            fileSystem.files[transcriptFile.path] = Data(TestFixtures.cursorTranscriptJSONLWithProjectHints(
                projectPath: genericProjectPath,
                filePath: sourceFile.path,
                preludePath: helperSkillFile.path
            ).utf8)

            return transcriptFile
        }

        /// Creates an unreadable `store.db` path so tests exercise transcript fallback behavior.
        mutating func configureUnreadableStoreDB() -> String {
            let workspaceDirectory = chatsRoot.appendingPathComponent(workspaceHash)
            let sessionDirectory = workspaceDirectory.appendingPathComponent(sessionID)
            let dbPath = sessionDirectory.appendingPathComponent("store.db").path

            fileSystem.directories[chatsRoot.path] = [workspaceDirectory]
            fileSystem.directories[workspaceDirectory.path] = [sessionDirectory]
            fileSystem.files[dbPath] = Data("db".utf8)

            return dbPath
        }

        func makeReader(sqlite: MockSQLiteReader = MockSQLiteReader(), baseDir: URL? = nil) -> CursorSessionReader {
            CursorSessionReader(
                fileSystem: fileSystem,
                sqlite: sqlite,
                baseDir: baseDir
            )
        }
    }

    @Test("listSessions returns empty when base dir missing")
    func listEmpty() async throws {
        let reader = CursorSessionReader(
            fileSystem: MockFileManager(),
            sqlite: MockSQLiteReader(),
            baseDir: URL(fileURLWithPath: "/nonexistent")
        )

        #expect(try await reader.listSessions().isEmpty)
    }

    @Test("loadSession falls back to agent-transcripts when store.db is unavailable")
    func loadFromTranscriptFallback() async throws {
        var fixture = Fixture()
        _ = fixture.configureLegacyTranscriptSession()

        let conversation = try #require(
            try await fixture.makeReader()
                .loadSession(id: "87245085-1456-4f87-a575-4a85b759cd1d")
        )
        #expect(conversation.source == .cursor)
        #expect(conversation.messages.count == 2)
        #expect(conversation.messages[0].role == .user)
        #expect(conversation.messages[0].content == "Hello from transcript")
        #expect(conversation.messages[1].role == .assistant)
        #expect(conversation.projectPath == fixture.legacyProjectPath)
    }

    @Test("loadSession falls back to nested agent-transcripts layout when store.db is unavailable")
    func loadFromNestedTranscriptFallback() async throws {
        var fixture = Fixture()
        _ = fixture.configureNestedTranscriptSession()
        _ = fixture.configureUnreadableStoreDB()

        let conversation = try #require(
            try await fixture.makeReader()
                .loadSession(id: fixture.sessionID)
        )
        #expect(conversation.source == .cursor)
        #expect(conversation.messages.count == 4)
        #expect(conversation.projectPath == fixture.genericProjectPath)
    }

    @Test("loadSession limit truncates transcript messages to the latest entries")
    func loadFromTranscriptWithLimit() async throws {
        var fixture = Fixture()
        _ = fixture.configureLegacyTranscriptSession()

        let conversation = try #require(
            try await fixture.makeReader()
                .loadSession(id: "87245085-1456-4f87-a575-4a85b759cd1d", limit: 1)
        )
        #expect(conversation.messages.count == 1)
        #expect(conversation.messages[0].role == .assistant)
        #expect(conversation.messages[0].content == "Hi from transcript")
    }

    @Test("loadSession limit uses recent blobs for store db")
    func loadFromRecentBlobs() async throws {
        let sqlite = MockSQLiteReader()
        sqlite.queryResults = [[
            "key": "composerData",
            "value": "7b226167656e744964223a22637572736f722d73657373696f6e222c226e616d65223a2254657374222c"
                + "2263726561746564"
                + "4174223a313731303030303030303030302c226c617374557365644d6f64656c223a226770742d34227d",
        ]]
        sqlite.recentBlobResults = [
            (
                id: "blob-last-user",
                data: Data(#"{"role":"user","content":[{"type":"text","text":"latest question"}]}"#.utf8)
            ),
            (
                id: "blob-last-assistant",
                data: Data(#"{"role":"assistant","content":[{"type":"text","text":"latest answer"}]}"#.utf8)
            ),
        ]

        let fileSystem = MockFileManager()
        let dbPath = "/mock/store.db"
        fileSystem.files[dbPath] = Data("db".utf8)

        let reader = CursorSessionReader(
            fileSystem: fileSystem,
            sqlite: sqlite,
            baseDir: URL(fileURLWithPath: "/nonexistent")
        )
        let conversation = try #require(try await reader.loadSession(
            id: "cursor-session",
            storagePath: dbPath,
            limit: 2
        ))

        #expect(sqlite.lastRecentBlobLimit == 800)
        #expect(conversation.messages.count == 2)
        #expect(conversation.messages[0].content == "latest question")
        #expect(conversation.messages[1].content == "latest answer")
    }

    @Test("loadSession restores projectPath from transcript when workspace metadata is unavailable")
    func loadFromStoreDBWithTranscriptProjectFallback() async throws {
        var fixture = Fixture()
        _ = fixture.configureNestedTranscriptSession()
        let dbPath = fixture.configureUnreadableStoreDB()

        let sqlite = MockSQLiteReader()
        sqlite.queryResults = [[
            "key": "composerData",
            "value": "7b226167656e744964223a2263396630356437352d623935382d343263662d393332622d623038316138323239"
                + "313734222c"
                + "226e616d65223a2254657374222c22637265617465644174223a313731303030303030303030302c"
                + "226c617374557365644d6f64656c223a226770742d34227d",
        ]]
        sqlite.blobResults = [
            (
                id: "blob1",
                data: Data(#"{"role":"user","content":[{"type":"text","text":"where am i working?"}]}"#.utf8)
            ),
        ]

        let conversation = try #require(
            try await fixture.makeReader(sqlite: sqlite)
                .loadSession(id: fixture.sessionID, storagePath: dbPath, limit: nil)
        )
        #expect(conversation.projectPath == fixture.genericProjectPath)
    }
}
