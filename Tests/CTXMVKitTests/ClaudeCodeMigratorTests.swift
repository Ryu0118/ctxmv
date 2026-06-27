@testable import CTXMVKit
import Foundation
import Testing

struct ClaudeCodeMigratorTests {
    private func encodedDir(home: URL, path: String) -> String {
        home.appendingPathComponent(".claude/projects")
            .appendingPathComponent(MigratorUtils.encodedClaudeProjectPath(path))
            .path
    }

    private func makeMigrator(
        projectPath: String,
        logicalCwd: String?
    ) -> (ClaudeCodeMigrator, home: URL, MockFileManager) {
        let fileSystem = MockFileManager()
        let home = URL(filePath: "/mock/home")
        fileSystem.homeDirectoryForCurrentUser = home
        let migrator = ClaudeCodeMigrator(fileSystem: fileSystem, projectPath: projectPath, logicalCwd: logicalCwd)
        return (migrator, home, fileSystem)
    }

    /// The directories that received a written `.jsonl` file.
    private func bucketsWritten(in fileSystem: MockFileManager) -> Set<String> {
        Set(fileSystem.files.keys.map { URL(filePath: $0).deletingLastPathComponent().path })
    }

    @Test("writes the session into both physical and symlink-aliased project buckets")
    func writesToBothBuckets() throws {
        let (physical, logical, cleanup) = try TestFixtures.makeSymlinkedProject()
        defer { cleanup() }

        let (migrator, home, fileSystem) = makeMigrator(projectPath: physical, logicalCwd: logical)
        _ = try migrator.migrate(TestFixtures.makeConversation(source: .codex, projectPath: physical))

        #expect(bucketsWritten(in: fileSystem) == [
            encodedDir(home: home, path: physical),
            encodedDir(home: home, path: logical),
        ])
    }

    @Test("writes only the physical bucket when there is no symlink alias")
    func writesSingleBucketWithoutAlias() throws {
        let physical = "/Volumes/Disk/workspace/proj"
        let (migrator, home, fileSystem) = makeMigrator(projectPath: physical, logicalCwd: physical)
        _ = try migrator.migrate(TestFixtures.makeConversation(source: .codex, projectPath: physical))

        #expect(bucketsWritten(in: fileSystem) == [encodedDir(home: home, path: physical)])
    }

    /// The Claude Code TUI rejects a migrated session ("Failed to resume") unless its JSONL matches
    /// the resume contract: no leading `progress` line, per-entry `cwd`/`version`/`gitBranch`/
    /// `isSidechain`, a `parentUuid` chain, and a `model` on assistant messages. These were confirmed
    /// empirically; this test guards against regressing any of them.
    @Test("emitted JSONL satisfies the Claude Code resume contract")
    func emitsResumableJSONL() throws {
        let physical = "/Volumes/Disk/workspace/proj"
        let (migrator, _, fileSystem) = makeMigrator(projectPath: physical, logicalCwd: physical)
        let conversation = TestFixtures.makeConversation(
            source: .codex,
            projectPath: physical,
            messages: [
                UnifiedMessage(role: .user, content: "Hello", timestamp: TestFixtures.sampleDate),
                UnifiedMessage(role: .assistant, content: "Hi", timestamp: TestFixtures.sampleDate),
            ]
        )
        _ = try migrator.migrate(conversation)

        let data = try #require(fileSystem.files.values.first)
        let lines = try parseJSONLines(data)

        // First line is the first conversation entry, not `progress`; the meta lives at the end.
        #expect(lines.first?["type"] as? String == "user")
        #expect(lines.last?["type"] as? String == "progress")
        #expect(lines.count { $0["type"] as? String == "progress" } == 1)

        let user = try #require(lines.first { $0["type"] as? String == "user" })
        #expect(user["cwd"] as? String == physical)
        #expect((user["version"] as? String)?.isEmpty == false)
        #expect(user["gitBranch"] != nil)
        #expect(user["isSidechain"] as? Bool == false)
        // The first entry roots the chain: it has no parent (the key is omitted, which resume accepts).
        #expect(user["parentUuid"] == nil)

        let assistant = try #require(lines.first { $0["type"] as? String == "assistant" })
        let message = try #require(assistant["message"] as? [String: Any])
        #expect((message["model"] as? String)?.isEmpty == false)
        // Later entries chain to the previous one's uuid.
        #expect(assistant["parentUuid"] as? String == user["uuid"] as? String)
    }

    private func parseJSONLines(_ data: Data) throws -> [[String: Any]] {
        let text = try #require(String(data: data, encoding: .utf8))
        return try text.split(separator: "\n").map { line in
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
            return try #require(object as? [String: Any])
        }
    }
}
