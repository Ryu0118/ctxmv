@testable import CTXMVKit
import Foundation
import Testing

@Suite("Verifies Codex migration output as structured entries and rollout files.")
struct CodexMigratorTests {
    @Test("makeDocument emits migration meta, session meta, and paired assistant entries")
    func makeDocumentBuildsStructuredDocument() throws {
        let builder = CodexSessionJSONLBuilder(workingDirectoryProvider: { "/fallback/cwd" })
        let conversation = TestFixtures.makeConversation(
            id: "codex-build-jsonl",
            source: .claudeCode,
            messages: [
                UnifiedMessage(role: .user, content: "Hello", timestamp: TestFixtures.sampleDate),
                UnifiedMessage(role: .assistant, content: "Hi there!", timestamp: nil),
            ]
        )

        let document = builder.makeDocument(conversation: conversation, sessionId: "session-123")

        #expect(document.migrationMetadata.originId == conversation.id)
        #expect(document.migrationMetadata.originSource == conversation.source.rawValue)
        // session_meta + one user event + paired assistant event/response_item
        #expect(document.entries.count == 4)

        let sessionMeta = try #require(document.entries.first)
        #expect(sessionMeta.entryType == .sessionMeta)
        #expect(sessionMeta.payload?.id == "session-123")
        #expect(sessionMeta.payload?.cwd == "/test/project")

        let userEntry = try #require(document.entries.dropFirst().first)
        #expect(userEntry.entryType == .eventMsg)
        #expect(userEntry.payload?.payloadType == .userMessage)
        #expect(userEntry.payload?.message == "Hello")

        let assistantEntries = Array(document.entries.suffix(2))
        #expect(assistantEntries.count == 2)
        #expect(assistantEntries.first?.payload?.payloadType == .agentMessage)
        #expect(assistantEntries.first?.payload?.message == "Hi there!")
        #expect(assistantEntries.last?.entryType == .responseItem)
        #expect(assistantEntries.last?.payload?.payloadRole == .assistant)
        #expect(assistantEntries.last?.payload?.content?.first?.text == "Hi there!")
    }

    @Test("makeDocument replaces the first noisy user prompt and skips unsupported roles")
    func makeDocumentSanitizesFirstNoiseAndSkipsUnsupportedRoles() throws {
        let builder = CodexSessionJSONLBuilder(workingDirectoryProvider: { "/fallback/cwd" })
        let conversation = TestFixtures.makeConversation(
            id: "codex-build-noise",
            source: .claudeCode,
            projectPath: nil,
            messages: [
                UnifiedMessage(
                    role: .user,
                    content: "<user_info>hidden</user_info>",
                    timestamp: TestFixtures.sampleDate
                ),
                UnifiedMessage(role: .system, content: "ignore", timestamp: TestFixtures.sampleDate),
                UnifiedMessage(
                    role: .user,
                    content: "[Local command output — do not respond unless explicitly asked]",
                    timestamp: TestFixtures.sampleDate
                ),
                UnifiedMessage(role: .tool, content: "ignore", timestamp: TestFixtures.sampleDate),
            ]
        )

        let document = builder.makeDocument(conversation: conversation, sessionId: "session-456")

        // session_meta + the two user-facing user messages; system/tool messages are omitted.
        #expect(document.entries.count == 3)
        #expect(document.entries.first?.payload?.cwd == "/fallback/cwd")

        let userEntries = document.entries.dropFirst()
        #expect(userEntries.count == 2)
        #expect(userEntries.first?.payload?.message == "(Command output)")
        #expect(userEntries.last?.payload?.message == "[Local command output — do not respond unless explicitly asked]")
    }

    @Test("jsonl(for:) renders newline-terminated JSONL")
    func jsonlRendersJSONLLines() throws {
        let builder = CodexSessionJSONLBuilder(workingDirectoryProvider: { "/fallback/cwd" })
        let conversation = TestFixtures.makeConversation(id: "codex-build-render", source: .codex)

        let jsonl = builder.jsonl(for: conversation, sessionId: "session-789")
        let lines = jsonl.split(separator: "\n").map(String.init)

        #expect(jsonl.hasSuffix("\n"))
        // migration meta + session_meta + user event + assistant event + assistant response_item
        #expect(lines.count == 5)

        let meta = try #require(decode(lines[0], as: MigrationMeta.self))
        #expect(meta.type == MigrationMeta.migrationType)

        let sessionMeta = try #require(decode(lines[1], as: CodexEntry.self))
        #expect(sessionMeta.entryType == .sessionMeta)
    }

    @Test("migrate writes rollout JSONL into a date-based directory")
    func migrateWritesRolloutFile() throws {
        let fileSystem = MockFileManager()
        let migrator = CodexMigrator(fileSystem: fileSystem)
        let conversation = TestFixtures.makeConversation(id: "codex-migrate-write", source: .claudeCode)

        let result = try migrator.migrate(conversation)
        guard case let .written(path, sessionId) = result else {
            Issue.record("Expected written migration result")
            return
        }

        let expectedDirectory = expectedSessionsDirectory(
            homeDirectory: fileSystem.homeDirectoryForCurrentUser,
            createdAt: conversation.createdAt
        )
        #expect(path.hasPrefix(expectedDirectory.path + "/rollout-"))
        #expect(path.hasSuffix("-\(sessionId).jsonl"))
        #expect(fileSystem.directories[expectedDirectory.path] != nil)

        guard let data = fileSystem.files[path], let jsonl = String(data: data, encoding: .utf8) else {
            Issue.record("Expected migrated JSONL to be written")
            return
        }

        #expect(jsonl.contains(#""type":"ctxmv_migration""#))
        #expect(jsonl.contains(#""type":"session_meta""#))
        #expect(jsonl.contains(#""type":"response_item""#))
    }

    @Test("migrate rejects an already-migrated conversation found recursively")
    func migrateRejectsDuplicateConversation() throws {
        let fileSystem = MockFileManager()
        let conversation = TestFixtures.makeConversation(id: "codex-migrate-duplicate", source: .claudeCode)
        let originDigest = MigrationDeduplicator.originDigest(for: conversation)

        let sessionsBase = fileSystem.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        let yearDirectory = sessionsBase.appendingPathComponent("2024", isDirectory: true)
        let monthDirectory = yearDirectory.appendingPathComponent("03", isDirectory: true)
        let dayDirectory = monthDirectory.appendingPathComponent("09", isDirectory: true)
        let existingFile = dayDirectory.appendingPathComponent("rollout-existing.jsonl")

        fileSystem.directories[sessionsBase.path] = [yearDirectory]
        fileSystem.directories[yearDirectory.path] = [monthDirectory]
        fileSystem.directories[monthDirectory.path] = [dayDirectory]
        fileSystem.directories[dayDirectory.path] = [existingFile]
        fileSystem.files[existingFile.path] = Data(
            ((MigrationDeduplicator.encodeMeta(
                originId: conversation.id,
                originSource: conversation.source,
                originMessageCount: conversation.messages.count,
                originDigest: originDigest
            ) ?? "") + "\n").utf8
        )

        let migrator = CodexMigrator(fileSystem: fileSystem)

        do {
            _ = try migrator.migrate(conversation)
            Issue.record("Expected already-migrated error")
        } catch let MigrationError.alreadyMigrated(existingPath) {
            #expect(existingPath == existingFile.path)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private func expectedSessionsDirectory(homeDirectory: URL, createdAt: Date) -> URL {
        let calendar = Calendar.current
        let year = calendar.component(.year, from: createdAt)
        let month = calendar.component(.month, from: createdAt)
        let day = calendar.component(.day, from: createdAt)

        return homeDirectory
            .appendingPathComponent(".codex/sessions", isDirectory: true)
            .appendingPathComponent(String(year), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", day), isDirectory: true)
    }

    private func decode<T: Decodable>(_ line: String, as type: T.Type) -> T? {
        guard let data = line.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }
}
