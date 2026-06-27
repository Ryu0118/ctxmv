@testable import CTXMVKit
import Foundation
import Testing

struct ClaudeCodeMigratorTests {
    /// Creates a real symlinked project layout so alias resolution (which resolves symlinks) runs
    /// against the filesystem, while a MockFileManager captures what gets written where.
    private func makeSymlink() throws -> (physical: String, logical: String, cleanup: () -> Void) {
        let base = URL(filePath: NSTemporaryDirectory())
            .appendingPathComponent("ctxmv-migrate-\(UUID().uuidString)")
        let physicalParent = base.appendingPathComponent("physical")
        let project = physicalParent.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let logicalParent = base.appendingPathComponent("logical")
        try FileManager.default.createSymbolicLink(at: logicalParent, withDestinationURL: physicalParent)

        let physical = project.resolvingSymlinksInPath().standardizedFileURL.path
        let logical = logicalParent.appendingPathComponent("proj").path
        return (physical, logical, { try? FileManager.default.removeItem(at: base) })
    }

    private func encodedDir(home: URL, path: String) -> String {
        home.appendingPathComponent(".claude/projects")
            .appendingPathComponent(MigratorUtils.encodedClaudeProjectPath(path))
            .path
    }

    @Test("writes the session into both physical and symlink-aliased project buckets")
    func writesToBothBuckets() throws {
        let (physical, logical, cleanup) = try makeSymlink()
        defer { cleanup() }

        let fileSystem = MockFileManager()
        let home = URL(filePath: "/mock/home")
        fileSystem.homeDirectoryForCurrentUser = home

        let migrator = ClaudeCodeMigrator(
            fileSystem: fileSystem,
            projectPath: physical,
            environment: ["PWD": logical]
        )
        let conversation = TestFixtures.makeConversation(source: .codex, projectPath: physical)

        _ = try migrator.migrate(conversation)

        let physicalDir = encodedDir(home: home, path: physical)
        let logicalDir = encodedDir(home: home, path: logical)
        let writtenInPhysical = fileSystem.files.keys.contains { $0.hasPrefix(physicalDir + "/") }
        let writtenInLogical = fileSystem.files.keys.contains { $0.hasPrefix(logicalDir + "/") }
        #expect(writtenInPhysical)
        #expect(writtenInLogical)
        #expect(physicalDir != logicalDir)
    }

    @Test("writes only the physical bucket when there is no symlink alias")
    func writesSingleBucketWithoutAlias() throws {
        let fileSystem = MockFileManager()
        let home = URL(filePath: "/mock/home")
        fileSystem.homeDirectoryForCurrentUser = home

        let physical = "/Volumes/Disk/workspace/proj"
        let migrator = ClaudeCodeMigrator(
            fileSystem: fileSystem,
            projectPath: physical,
            environment: ["PWD": physical]
        )
        let conversation = TestFixtures.makeConversation(source: .codex, projectPath: physical)

        _ = try migrator.migrate(conversation)

        let physicalDir = encodedDir(home: home, path: physical)
        let bucketsWritten = Set(fileSystem.files.keys.map { URL(filePath: $0).deletingLastPathComponent().path })
        #expect(bucketsWritten == [physicalDir])
    }
}
