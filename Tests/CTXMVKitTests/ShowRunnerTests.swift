@testable import CTXMVKit
import Foundation
import Testing

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

    /// Load-limit behavior when resolving from `SessionSummary` (auto cap vs explicit `messageLimit`).
    private struct LoadLimitScenario: CustomTestStringConvertible {
        var testDescription: String {
            name
        }

        let name: String
        let byteSize: Int64
        let messageLimit: Int?
        let source: AgentSource
        let sessionID: String
        let summaryStoragePath: String?
        let expectedLoadLimit: Int?
        let expectedLoadedStoragePath: String?
    }

    private static let loadLimitScenarios: [LoadLimitScenario] = [
        LoadLimitScenario(
            name: "auto-limits large sessions by byte size",
            byteSize: 2_000_000,
            messageLimit: nil,
            source: .claudeCode,
            sessionID: "session-large",
            summaryStoragePath: nil,
            expectedLoadLimit: 100,
            expectedLoadedStoragePath: nil
        ),
        LoadLimitScenario(
            name: "small sessions are loaded without truncation by default",
            byteSize: 128_000,
            messageLimit: nil,
            source: .codex,
            sessionID: "session-small",
            summaryStoragePath: nil,
            expectedLoadLimit: nil,
            expectedLoadedStoragePath: nil
        ),
        LoadLimitScenario(
            name: "explicit message limit overrides auto-limit policy",
            byteSize: 128_000,
            messageLimit: 5,
            source: .cursor,
            sessionID: "session-explicit",
            summaryStoragePath: "/tmp/store.db",
            expectedLoadLimit: 5,
            expectedLoadedStoragePath: "/tmp/store.db"
        ),
    ]

    @Test("applies load-limit policy from summary and runner options", arguments: loadLimitScenarios)
    private func loadLimitPolicy(_ scenario: LoadLimitScenario) async throws {
        let summary = SessionSummary(
            id: scenario.sessionID,
            source: scenario.source,
            projectPath: "/tmp/project",
            createdAt: TestFixtures.sampleDate,
            model: nil,
            messageCount: 0,
            lastUserMessage: "Hello",
            byteSize: scenario.byteSize,
            storagePath: scenario.summaryStoragePath
        )
        let reader = TrackingSessionReader(
            source: scenario.source,
            summaries: [summary],
            conversation: TestFixtures.makeConversation(id: scenario.sessionID, source: scenario.source)
        )

        let runner = ShowRunner(
            sessionID: scenario.sessionID,
            messageLimit: scenario.messageLimit,
            readers: [reader]
        )
        _ = try #require(try await runner.findSession())
        #expect(reader.lastLoadLimit == scenario.expectedLoadLimit)
        #expect(reader.lastLoadedStoragePath == scenario.expectedLoadedStoragePath)
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
        let conversation = try #require(try await runner.findSession())
        #expect(conversation.id == fullID)
    }
}
