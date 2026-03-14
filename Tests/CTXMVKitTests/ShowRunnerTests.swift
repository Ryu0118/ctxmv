@testable import CTXMVKit
import Foundation
import Testing

@Suite("Verifies show-session lookup and auto-limit policy without real providers.")
struct ShowRunnerTests {
    /// Spy provider that records how `ShowRunner` attempts to load sessions.
    final class TrackingSessionReader: SessionReader, @unchecked Sendable {
        let source: AgentSource
        var summaries: [SessionSummary]
        var conversation: UnifiedConversation
        /// Captures the resolved message limit policy applied by the runner.
        var lastLoadLimit: Int?
        /// Captures the storage path chosen from `SessionSummary` when available.
        var lastLoadedStoragePath: String?

        init(source: AgentSource, summaries: [SessionSummary], conversation: UnifiedConversation) {
            self.source = source
            self.summaries = summaries
            self.conversation = conversation
        }

        func listSessions() async throws -> [SessionSummary] {
            summaries
        }

        func loadSession(id: String, storagePath: String?, limit: Int?) async throws -> UnifiedConversation? {
            lastLoadLimit = limit
            lastLoadedStoragePath = storagePath
            return conversation.id == id ? conversation : nil
        }
    }

    @Test("auto-limits large sessions by byte size")
    func autoLimitsLargeSessions() async throws {
        let summary = SessionSummary(
            id: "session-large",
            source: .claudeCode,
            projectPath: "/tmp/project",
            createdAt: TestFixtures.sampleDate,
            model: nil,
            messageCount: 0,
            lastUserMessage: "Hello",
            byteSize: 2_000_000
        )
        let reader = TrackingSessionReader(
            source: .claudeCode,
            summaries: [summary],
            conversation: TestFixtures.makeConversation(id: "session-large")
        )

        let runner = ShowRunner(sessionID: "session-large", readers: [reader])
        let conversation = try await runner.findSession()

        #expect(conversation != nil)
        #expect(reader.lastLoadLimit == 100)
    }

    @Test("small sessions are loaded without truncation by default")
    func smallSessionsLoadFully() async throws {
        let summary = SessionSummary(
            id: "session-small",
            source: .codex,
            projectPath: "/tmp/project",
            createdAt: TestFixtures.sampleDate,
            model: nil,
            messageCount: 0,
            lastUserMessage: "Hello",
            byteSize: 128_000
        )
        let reader = TrackingSessionReader(
            source: .codex,
            summaries: [summary],
            conversation: TestFixtures.makeConversation(id: "session-small", source: .codex)
        )

        let runner = ShowRunner(sessionID: "session-small", readers: [reader])
        let conversation = try await runner.findSession()

        #expect(conversation != nil)
        #expect(reader.lastLoadLimit == nil)
    }

    @Test("explicit message limit overrides auto-limit policy")
    func explicitLimitWins() async throws {
        let summary = SessionSummary(
            id: "session-explicit",
            source: .cursor,
            projectPath: "/tmp/project",
            createdAt: TestFixtures.sampleDate,
            model: nil,
            messageCount: 0,
            lastUserMessage: "Hello",
            byteSize: 128_000,
            storagePath: "/tmp/store.db"
        )
        let reader = TrackingSessionReader(
            source: .cursor,
            summaries: [summary],
            conversation: TestFixtures.makeConversation(id: "session-explicit", source: .cursor)
        )

        let runner = ShowRunner(
            sessionID: "session-explicit",
            messageLimit: 5,
            readers: [reader]
        )
        let conversation = try await runner.findSession()

        #expect(conversation != nil)
        #expect(reader.lastLoadLimit == 5)
        #expect(reader.lastLoadedStoragePath == "/tmp/store.db")
    }

    @Test("short id can resolve by listed suffix")
    func resolvesBySuffixShorthand() async throws {
        let fullID = "11111111-2222-3333-4444-555566667777"
        let summary = SessionSummary(
            id: fullID,
            source: .claudeCode,
            projectPath: "/tmp/project",
            createdAt: TestFixtures.sampleDate,
            model: nil,
            messageCount: 1,
            lastUserMessage: "hello"
        )
        let reader = TrackingSessionReader(
            source: .claudeCode,
            summaries: [summary],
            conversation: TestFixtures.makeConversation(id: fullID, source: .claudeCode)
        )

        let runner = ShowRunner(sessionID: "66667777", readers: [reader])
        let conversation = try await runner.findSession()

        #expect(conversation?.id == fullID)
    }
}
