@testable import CTXMVKit
import Foundation
import Testing

@Suite("Covers recursive dedup lookup plus digest and count fallback behavior.")
struct MigrationDeduplicatorTests {
    @Test("findExistingMigrationRecursive finds a duplicate in nested year/month/day directories")
    func recursiveFindsNestedDuplicate() {
        let fileSystem = MockFileManager()
        let baseDir = URL(fileURLWithPath: "/mock/sessions")
        let yearDir = baseDir.appendingPathComponent("2024", isDirectory: true)
        let monthDir = yearDir.appendingPathComponent("03", isDirectory: true)
        let dayDir = monthDir.appendingPathComponent("09", isDirectory: true)
        let file = dayDir.appendingPathComponent("rollout-existing.jsonl")

        fileSystem.directories[baseDir.path] = [yearDir]
        fileSystem.directories[yearDir.path] = [monthDir]
        fileSystem.directories[monthDir.path] = [dayDir]
        fileSystem.directories[dayDir.path] = [file]
        let metaLine = #"{"type":"ctxmv_migration","originId":"session-1","originSource":"codex","#
            + #""originMessageCount":3,"originDigest":"abc123"}"#
        fileSystem.files[file.path] = Data(metaLine.utf8)

        let origin = MigrationOrigin(
            originId: "session-1",
            originSource: .codex,
            originMessageCount: 3,
            originDigest: "abc123"
        )
        let existing = MigrationDeduplicator.findExistingMigrationRecursive(
            origin: origin,
            in: baseDir,
            fileSystem: fileSystem
        )

        #expect(existing == file.path)
    }

    @Test("findExistingMigrationRecursive skips unreadable branches and keeps searching")
    func recursiveSkipsUnreadableBranches() {
        let fileSystem = MockFileManager()
        let baseDir = URL(fileURLWithPath: "/mock/sessions")
        let brokenYearDir = baseDir.appendingPathComponent("broken", isDirectory: true)
        let validYearDir = baseDir.appendingPathComponent("2024", isDirectory: true)
        let monthDir = validYearDir.appendingPathComponent("03", isDirectory: true)
        let dayDir = monthDir.appendingPathComponent("09", isDirectory: true)
        let file = dayDir.appendingPathComponent("rollout-existing.jsonl")

        fileSystem.directories[baseDir.path] = [brokenYearDir, validYearDir]
        fileSystem.directories[validYearDir.path] = [monthDir]
        fileSystem.directories[monthDir.path] = [dayDir]
        fileSystem.directories[dayDir.path] = [file]
        let metaLine = #"{"type":"ctxmv_migration","originId":"session-1","originSource":"codex","#
            + #""originMessageCount":3,"originDigest":"abc123"}"#
        fileSystem.files[file.path] = Data(metaLine.utf8)

        let origin = MigrationOrigin(
            originId: "session-1",
            originSource: .codex,
            originMessageCount: 3,
            originDigest: "abc123"
        )
        let existing = MigrationDeduplicator.findExistingMigrationRecursive(
            origin: origin,
            in: baseDir,
            fileSystem: fileSystem
        )

        #expect(existing == file.path)
    }

    @Test("findExistingMigrationRecursive ignores non-directory entries while searching")
    func recursiveIgnoresNonDirectoryEntries() {
        let fileSystem = MockFileManager()
        let baseDir = URL(fileURLWithPath: "/mock/sessions")
        let strayFile = baseDir.appendingPathComponent("notes.txt")
        let yearDir = baseDir.appendingPathComponent("2024", isDirectory: true)
        let monthDir = yearDir.appendingPathComponent("03", isDirectory: true)
        let dayDir = monthDir.appendingPathComponent("09", isDirectory: true)
        let file = dayDir.appendingPathComponent("rollout-existing.jsonl")

        fileSystem.directories[baseDir.path] = [strayFile, yearDir]
        fileSystem.files[strayFile.path] = Data("ignore me".utf8)
        fileSystem.directories[yearDir.path] = [monthDir]
        fileSystem.directories[monthDir.path] = [dayDir]
        fileSystem.directories[dayDir.path] = [file]
        let metaLine = #"{"type":"ctxmv_migration","originId":"session-1","originSource":"codex","#
            + #""originMessageCount":3,"originDigest":"abc123"}"#
        fileSystem.files[file.path] = Data(metaLine.utf8)

        let origin = MigrationOrigin(
            originId: "session-1",
            originSource: .codex,
            originMessageCount: 3,
            originDigest: "abc123"
        )
        let existing = MigrationDeduplicator.findExistingMigrationRecursive(
            origin: origin,
            in: baseDir,
            fileSystem: fileSystem
        )

        #expect(existing == file.path)
    }

    @Test("deduplicates only when origin digest matches")
    func digestMatch() {
        let fileSystem = MockFileManager()
        let dir = URL(fileURLWithPath: "/mock/migrations")
        let file = dir.appendingPathComponent("target.jsonl")
        fileSystem.directories[dir.path] = [file]
        let metaLine = #"{"type":"ctxmv_migration","originId":"session-1","originSource":"codex","#
            + #""originMessageCount":3,"originDigest":"abc123"}"#
        fileSystem.files[file.path] = Data(metaLine.utf8)

        let origin = MigrationOrigin(
            originId: "session-1",
            originSource: .codex,
            originMessageCount: 3,
            originDigest: "abc123"
        )
        let existing = MigrationDeduplicator.findExistingMigration(
            origin: origin,
            in: dir,
            fileSystem: fileSystem
        )

        #expect(existing == file.path)
    }

    @Test("allows remigration when digest differs even if message count is same")
    func digestMismatch() {
        let fileSystem = MockFileManager()
        let dir = URL(fileURLWithPath: "/mock/migrations")
        let file = dir.appendingPathComponent("target.jsonl")
        fileSystem.directories[dir.path] = [file]
        let metaLine = #"{"type":"ctxmv_migration","originId":"session-1","originSource":"codex","#
            + #""originMessageCount":3,"originDigest":"old-digest"}"#
        fileSystem.files[file.path] = Data(metaLine.utf8)

        let origin = MigrationOrigin(
            originId: "session-1",
            originSource: .codex,
            originMessageCount: 3,
            originDigest: "new-digest"
        )
        let existing = MigrationDeduplicator.findExistingMigration(
            origin: origin,
            in: dir,
            fileSystem: fileSystem
        )

        #expect(existing == nil)
    }

    @Test("legacy metadata falls back to exact message count equality")
    func legacyExactCountFallback() {
        let fileSystem = MockFileManager()
        let dir = URL(fileURLWithPath: "/mock/migrations")
        let file = dir.appendingPathComponent("legacy.jsonl")
        fileSystem.directories[dir.path] = [file]
        let metaLine = #"{"type":"ctxmv_migration","originId":"session-1","originSource":"codex","#
            + #""originMessageCount":3}"#
        fileSystem.files[file.path] = Data(metaLine.utf8)

        let origin = MigrationOrigin(
            originId: "session-1",
            originSource: .codex,
            originMessageCount: 3,
            originDigest: "any"
        )
        let existing = MigrationDeduplicator.findExistingMigration(
            origin: origin,
            in: dir,
            fileSystem: fileSystem
        )

        #expect(existing == file.path)
    }

    @Test("legacy metadata does not block when origin has newer messages")
    func legacyUpdatedConversation() {
        let fileSystem = MockFileManager()
        let dir = URL(fileURLWithPath: "/mock/migrations")
        let file = dir.appendingPathComponent("legacy.jsonl")
        fileSystem.directories[dir.path] = [file]
        let metaLine = #"{"type":"ctxmv_migration","originId":"session-1","originSource":"codex","#
            + #""originMessageCount":3}"#
        fileSystem.files[file.path] = Data(metaLine.utf8)

        let origin = MigrationOrigin(
            originId: "session-1",
            originSource: .codex,
            originMessageCount: 4,
            originDigest: "any"
        )
        let existing = MigrationDeduplicator.findExistingMigration(
            origin: origin,
            in: dir,
            fileSystem: fileSystem
        )

        #expect(existing == nil)
    }
}
