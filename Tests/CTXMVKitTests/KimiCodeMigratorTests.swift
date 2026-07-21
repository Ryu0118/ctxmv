@testable import CTXMVKit
import Foundation
import Testing

struct KimiCodeMigratorTests {
    private func makeMigrator(_ mockFS: MockFileManager) -> KimiCodeMigrator {
        KimiCodeMigrator(fileSystem: mockFS)
    }

    /// Shared arrange+act step for the `migrateWritesFiles*` tests below: one migrated
    /// session, each test then asserts a single facet of what got written.
    private func makeMigratedSession() throws -> (mockFS: MockFileManager, path: String, sessionID: String) {
        let mockFS = MockFileManager()
        mockFS.homeDirectoryForCurrentUser = URL(fileURLWithPath: "/Users/tester")
        let convo = TestFixtures.makeConversation(id: "src-1", source: .claudeCode, projectPath: "/proj")

        guard case let .written(path, sessionID) = try makeMigrator(mockFS).migrate(convo) else {
            Issue.record("expected .written")
            throw MigrationError.writeFailed("test setup failed")
        }
        return (mockFS, path, sessionID)
    }

    @Test("migrate names the session with a session_ prefix and paths it under that ID")
    func migrateWritesFilesSessionIDAndPath() throws {
        let (_, path, sessionID) = try makeMigratedSession()
        #expect(sessionID.hasPrefix("session_"))
        #expect(path.hasSuffix(sessionID))
    }

    @Test("migrate writes state.json and wire.jsonl into the session directory")
    func migrateWritesFilesStateAndWire() throws {
        let (mockFS, path, _) = try makeMigratedSession()
        #expect(mockFS.files[path + "/state.json"] != nil)
        #expect(mockFS.files[path + "/agents/main/wire.jsonl"] != nil)
    }

    @Test("migrate appends the new session ID to session_index.jsonl")
    func migrateWritesFilesAppendsSessionIndex() throws {
        let (mockFS, _, sessionID) = try makeMigratedSession()
        let indexPath = "/Users/tester/.kimi-code/session_index.jsonl"
        let index = try #require(mockFS.files[indexPath]).flatMap { String(data: $0, encoding: .utf8) }
        #expect(index?.contains(sessionID) == true)
    }

    @Test("migrate registers the workspace under a wd_<basename>_<hash> key")
    func migrateWritesFilesRegistersWorkspace() throws {
        let (mockFS, _, _) = try makeMigratedSession()
        let wsPath = "/Users/tester/.kimi-code/workspaces.json"
        let wsData = try #require(mockFS.files[wsPath])
        let wsObject = try #require((try? JSONSerialization.jsonObject(with: wsData)) as? [String: Any])
        let workspaces = try #require(wsObject["workspaces"] as? [String: Any])
        #expect(workspaces.keys.contains { $0.hasPrefix("wd_proj_") })
    }

    @Test("re-migrating the same conversation is blocked as already migrated")
    func migrateIsIdempotent() throws {
        let mockFS = MockFileManager()
        mockFS.homeDirectoryForCurrentUser = URL(fileURLWithPath: "/Users/tester")
        let convo = TestFixtures.makeConversation(id: "src-dup", source: .codex, projectPath: "/proj")

        let first = try makeMigrator(mockFS).migrate(convo)
        guard case let .written(firstPath, _) = first else { Issue.record("expected .written"); return }

        let error = #expect(throws: MigrationError.self) {
            try makeMigrator(mockFS).migrate(convo)
        }
        guard case let .alreadyMigrated(existingPath) = error else {
            Issue.record("expected .alreadyMigrated"); return
        }
        #expect(existingPath == firstPath)
    }

    @Test("re-migrating an updated source (different content/digest) is allowed and writes a second session")
    func migrateAllowsUpdatedSource() throws {
        let mockFS = MockFileManager()
        mockFS.homeDirectoryForCurrentUser = URL(fileURLWithPath: "/Users/tester")
        let migrator = makeMigrator(mockFS)

        let original = TestFixtures.makeConversation(
            id: "src-updated",
            source: .codex,
            projectPath: "/proj",
            messages: [
                UnifiedMessage(role: .user, content: "Question one", timestamp: TestFixtures.sampleDate),
                UnifiedMessage(role: .assistant, content: "Answer one", timestamp: TestFixtures.sampleDate),
            ]
        )
        let updated = TestFixtures.makeConversation(
            id: "src-updated",
            source: .codex,
            projectPath: "/proj",
            messages: [
                UnifiedMessage(role: .user, content: "Question one", timestamp: TestFixtures.sampleDate),
                UnifiedMessage(role: .assistant, content: "Answer one", timestamp: TestFixtures.sampleDate),
                UnifiedMessage(role: .user, content: "Follow-up question", timestamp: TestFixtures.sampleDate),
                UnifiedMessage(role: .assistant, content: "Follow-up answer", timestamp: TestFixtures.sampleDate),
            ]
        )

        guard case let .written(firstPath, firstID) = try migrator.migrate(original) else {
            Issue.record("expected .written for the original conversation"); return
        }
        guard case let .written(secondPath, secondID) = try migrator.migrate(updated) else {
            Issue.record("expected .written for the updated conversation"); return
        }

        #expect(firstPath != secondPath)
        #expect(firstID != secondID)
        #expect(mockFS.files[firstPath + "/state.json"] != nil)
        #expect(mockFS.files[secondPath + "/state.json"] != nil)
    }

    @Test("empty conversation is rejected")
    func migrateRejectsEmpty() {
        let mockFS = MockFileManager()
        mockFS.homeDirectoryForCurrentUser = URL(fileURLWithPath: "/Users/tester")
        let convo = TestFixtures.makeConversation(id: "empty", messages: [])
        #expect(throws: MigrationError.self) { try makeMigrator(mockFS).migrate(convo) }
    }

    @Test("corrupt workspaces.json fails closed before any file is written")
    func migrateFailsClosedOnCorruptWorkspaces() {
        let mockFS = MockFileManager()
        mockFS.homeDirectoryForCurrentUser = URL(fileURLWithPath: "/Users/tester")
        mockFS.files["/Users/tester/.kimi-code/workspaces.json"] = Data("{not json".utf8)
        let convo = TestFixtures.makeConversation(id: "corrupt", source: .codex, projectPath: "/proj")

        #expect(throws: MigrationError.self) { try makeMigrator(mockFS).migrate(convo) }
        // Nothing may be created when the registry can't be parsed safely.
        #expect(mockFS.files.count == 1)
    }

    @Test("round-trip: written session reads back through KimiCodeSessionReader")
    func roundTrip() async throws {
        let mockFS = MockFileManager()
        mockFS.homeDirectoryForCurrentUser = URL(fileURLWithPath: "/Users/tester")
        let convo = TestFixtures.makeConversation(
            id: "rt",
            source: .claudeCode,
            projectPath: "/proj",
            messages: [
                UnifiedMessage(role: .user, content: "Question one", timestamp: TestFixtures.sampleDate),
                UnifiedMessage(role: .assistant, content: "Answer one", timestamp: TestFixtures.sampleDate),
            ]
        )
        guard case let .written(path, sessionID) = try makeMigrator(mockFS).migrate(convo) else {
            Issue.record("expected .written"); return
        }

        let reader = KimiCodeSessionReader(fileSystem: mockFS)
        let restored = try #require(try await reader.loadSession(id: sessionID, storagePath: path))
        #expect(restored.messages.count == 2)
        #expect(restored.messages[0].role == .user)
        #expect(restored.messages[0].content == "Question one")
        #expect(restored.messages[1].role == .assistant)
        #expect(restored.messages[1].content == "Answer one")
    }

    @Test("two migrations append two lines to session_index.jsonl")
    func twoMigrationsAppendIndexLines() throws {
        let mockFS = MockFileManager()
        mockFS.homeDirectoryForCurrentUser = URL(fileURLWithPath: "/Users/tester")
        let migrator = KimiCodeMigrator(fileSystem: mockFS)
        _ = try migrator.migrate(TestFixtures.makeConversation(id: "conv-a", source: .claudeCode, projectPath: "/pa"))
        _ = try migrator.migrate(TestFixtures.makeConversation(id: "conv-b", source: .codex, projectPath: "/pb"))
        let indexText = mockFS.files["/Users/tester/.kimi-code/session_index.jsonl"]
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let lines = indexText.split(separator: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 2)
    }
}
