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
}
