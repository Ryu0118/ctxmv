@testable import CTXMVKit
import Foundation
import Testing

struct CopilotCLIMigratorTests {
    private let home = URL(filePath: "/synthetic/home", isDirectory: true)
    private let copilotHome = URL(filePath: "/synthetic/home/.copilot", isDirectory: true)
    private let projectPath = "/synthetic/project:with # characters"

    @Test("migration uses the supported semantic import format")
    func migrateImportsSemanticSession() throws {
        let fileSystem = MockFileManager()
        fileSystem.homeDirectoryForCurrentUser = home
        let importer = MockCopilotSessionImporter(
            sessionIDs: ["11111111-2222-4333-8444-555555555555"],
            fileSystem: fileSystem
        )
        let conversation = TestFixtures.makeConversation(
            id: "synthetic-origin-session",
            source: .codex,
            projectPath: projectPath,
            messages: [
                UnifiedMessage(
                    role: .user,
                    content: "Synthetic question with a quote: \"hello\"\nsecond line",
                    timestamp: TestFixtures.sampleDate
                ),
                UnifiedMessage(role: .assistant, content: "Synthetic answer", timestamp: TestFixtures.sampleDate),
                UnifiedMessage(role: .tool, content: "Synthetic tool output", timestamp: TestFixtures.sampleDate),
                UnifiedMessage(role: .user, content: "Synthetic follow-up", timestamp: TestFixtures.sampleDate),
            ]
        )

        let result = try CopilotCLIMigrator(
            fileSystem: fileSystem,
            copilotHome: copilotHome,
            importer: importer
        ).migrate(conversation)

        guard case let .written(path, sessionID) = result else {
            Issue.record("expected .written")
            return
        }
        #expect(sessionID == "11111111-2222-4333-8444-555555555555")
        #expect(path == copilotHome.appendingPathComponent("session-state/\(sessionID)").path)
        #expect(importer.calls.count == 1)
        #expect(importer.calls[0].workingDirectory == projectPath)
        #expect(importer.calls[0].copilotHome == copilotHome)
        try assertSemanticJSONL(importer.calls[0].semanticJSONL)

        let markerData = try #require(
            fileSystem.files.first { $0.key.contains("/ctxmv-migrations/copilot-cli/") }?.value
        )
        let marker = try #require(JSONSerialization.jsonObject(with: markerData) as? [String: Any])
        #expect(marker["targetSessionID"] as? String == sessionID)
        let origin = try #require(marker["origin"] as? [String: Any])
        #expect(origin["type"] as? String == MigrationMeta.migrationType)
        #expect(origin["originId"] as? String == "synthetic-origin-session")
    }

    @Test("migration marker prevents duplicate Copilot sessions")
    func migrateIsIdempotent() throws {
        let fileSystem = MockFileManager()
        fileSystem.homeDirectoryForCurrentUser = home
        let importer = MockCopilotSessionImporter(
            sessionIDs: ["aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"],
            fileSystem: fileSystem
        )
        let conversation = TestFixtures.makeConversation(
            id: "synthetic-duplicate-origin",
            source: .claudeCode,
            projectPath: projectPath
        )
        let migrator = CopilotCLIMigrator(fileSystem: fileSystem, copilotHome: copilotHome, importer: importer)

        guard case let .written(firstPath, _) = try migrator.migrate(conversation) else {
            Issue.record("expected first migration to be written")
            return
        }
        let error = #expect(throws: MigrationError.self) {
            try migrator.migrate(conversation)
        }
        guard case let .alreadyMigrated(existingPath) = error else {
            Issue.record("expected duplicate migration to be rejected")
            return
        }
        #expect(existingPath == firstPath)
        #expect(importer.calls.count == 1)
    }

    @Test("migration allows an updated source conversation")
    func migrateAllowsUpdatedSource() throws {
        let fileSystem = MockFileManager()
        fileSystem.homeDirectoryForCurrentUser = home
        let importer = MockCopilotSessionImporter(
            sessionIDs: [
                "11111111-1111-4111-8111-111111111111",
                "22222222-2222-4222-8222-222222222222",
            ],
            fileSystem: fileSystem
        )
        let migrator = CopilotCLIMigrator(fileSystem: fileSystem, copilotHome: copilotHome, importer: importer)
        let original = TestFixtures.makeConversation(
            id: "synthetic-updated-origin",
            source: .codex,
            projectPath: projectPath
        )
        let updated = TestFixtures.makeConversation(
            id: "synthetic-updated-origin",
            source: .codex,
            projectPath: projectPath,
            messages: [
                UnifiedMessage(role: .user, content: "Synthetic question", timestamp: TestFixtures.sampleDate),
                UnifiedMessage(role: .assistant, content: "Synthetic answer", timestamp: TestFixtures.sampleDate),
                UnifiedMessage(role: .user, content: "Synthetic new question", timestamp: TestFixtures.sampleDate),
                UnifiedMessage(role: .assistant, content: "Synthetic new answer", timestamp: TestFixtures.sampleDate),
            ]
        )

        guard case let .written(originalPath, _) = try migrator.migrate(original),
              case let .written(updatedPath, _) = try migrator.migrate(updated) else {
            Issue.record("expected both source snapshots to be written")
            return
        }
        #expect(originalPath != updatedPath)
        #expect(importer.calls.count == 2)
    }

    @Test("conversations without user or assistant messages are rejected")
    func migrateRejectsNonConversationalContent() {
        let fileSystem = MockFileManager()
        let importer = MockCopilotSessionImporter(sessionIDs: [], fileSystem: fileSystem)
        let conversation = TestFixtures.makeConversation(
            id: "synthetic-empty",
            messages: [
                UnifiedMessage(role: .tool, content: "Synthetic tool output", timestamp: TestFixtures.sampleDate),
            ]
        )

        #expect(throws: MigrationError.self) {
            try CopilotCLIMigrator(
                fileSystem: fileSystem,
                copilotHome: copilotHome,
                importer: importer
            ).migrate(conversation)
        }
        #expect(importer.calls.isEmpty)
        #expect(fileSystem.files.isEmpty)
    }

    @Test("invalid IDs returned by the CLI are rejected")
    func rejectsInvalidImportedSessionID() {
        let fileSystem = MockFileManager()
        let importer = MockCopilotSessionImporter(sessionIDs: ["../../unsafe"], fileSystem: fileSystem)
        let conversation = TestFixtures.makeConversation(id: "synthetic-invalid-id")

        #expect(throws: MigrationError.self) {
            try CopilotCLIMigrator(
                fileSystem: fileSystem,
                copilotHome: copilotHome,
                importer: importer
            ).migrate(conversation)
        }
        #expect(fileSystem.files.isEmpty)
    }

    @Test("MigrateRunner routes copilot-cli targets through the official importer")
    func runnerUsesCopilotImporter() async throws {
        let fileSystem = MockFileManager()
        fileSystem.homeDirectoryForCurrentUser = home
        let importer = MockCopilotSessionImporter(
            sessionIDs: ["33333333-3333-4333-8333-333333333333"],
            fileSystem: fileSystem
        )
        let conversation = TestFixtures.makeConversation(
            id: "44444444-4444-4444-8444-444444444444",
            source: .codex,
            projectPath: projectPath
        )
        let runner = MigrateRunner(
            sessionID: conversation.id,
            target: .copilotCLI,
            source: .codex,
            readers: [CopilotStubReader(conversation: conversation)],
            fileSystem: fileSystem,
            copilotSessionImporter: importer,
            copilotHome: copilotHome
        )

        try await runner.run()

        #expect(fileSystem.files.keys.contains { $0.contains("/ctxmv-migrations/copilot-cli/") })
        #expect(importer.calls.count == 1)
        #expect(importer.calls[0].workingDirectory == projectPath)
    }

    private func assertSemanticJSONL(_ jsonl: String) throws {
        var lines: [[String: Any]] = []
        for line in jsonl.split(separator: "\n") {
            lines.append(try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]))
        }
        let header = try #require(lines.first)
        #expect(header["type"] as? String == "session")
        #expect(header["version"] as? Int == 1)
        #expect((header["externalId"] as? String)?.hasPrefix("ctxmv-") == true)
        let source = try #require(header["source"] as? [String: Any])
        #expect(source["application"] as? String == "ctxmv")

        let messages = Array(lines.dropFirst())
        #expect(messages.count == 3)
        #expect(messages.compactMap { $0["role"] as? String } == ["user", "assistant", "user"])
        let firstMessage = try #require(messages.first)
        let firstContent = try #require(firstMessage["content"] as? [[String: Any]])
        #expect(firstContent.first?["text"] as? String == "Synthetic question with a quote: \"hello\"\nsecond line")
        #expect(!jsonl.contains("Synthetic tool output"))
    }
}

private struct CopilotStubReader: SessionReader {
    let conversation: UnifiedConversation
    var source: AgentSource { conversation.source }

    func listSessions() async throws -> [SessionSummary] {
        []
    }

    func loadSession(id: String, storagePath: String?, limit: Int?) async throws -> UnifiedConversation? {
        id == conversation.id ? conversation : nil
    }
}

private final class MockCopilotSessionImporter: CopilotSessionImporter, @unchecked Sendable {
    struct Call {
        let semanticJSONL: String
        let workingDirectory: String
        let copilotHome: URL
    }

    private let sessionIDs: [String]
    private let fileSystem: MockFileManager
    private(set) var calls: [Call] = []

    init(sessionIDs: [String], fileSystem: MockFileManager) {
        self.sessionIDs = sessionIDs
        self.fileSystem = fileSystem
    }

    func importSession(semanticJSONL: String, workingDirectory: String, copilotHome: URL) throws -> String {
        calls.append(Call(
            semanticJSONL: semanticJSONL,
            workingDirectory: workingDirectory,
            copilotHome: copilotHome
        ))
        let index = calls.count - 1
        guard sessionIDs.indices.contains(index) else {
            throw MigrationError.writeFailed("Mock importer ran out of synthetic session IDs.")
        }
        let sessionID = sessionIDs[index]
        let sessionsDirectory = copilotHome.appendingPathComponent("session-state", isDirectory: true)
        let sessionDirectory = sessionsDirectory.appendingPathComponent(sessionID, isDirectory: true)
        fileSystem.directories[sessionsDirectory.path, default: []].append(sessionDirectory)
        fileSystem.directories[sessionDirectory.path] = []
        return sessionID
    }
}
