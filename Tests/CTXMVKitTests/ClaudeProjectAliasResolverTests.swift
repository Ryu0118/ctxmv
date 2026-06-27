@testable import CTXMVKit
import Foundation
import Testing

@Suite
struct ClaudeProjectAliasResolverTests {
    /// Creates a real symlink `link -> target` inside a fresh temp directory, returning both paths.
    /// Uses the real filesystem because alias resolution relies on symlink resolution semantics.
    private func makeSymlink() throws -> (physical: String, logical: String, cleanup: () -> Void) {
        let base = URL(filePath: NSTemporaryDirectory())
            .appendingPathComponent("ctxmv-alias-\(UUID().uuidString)")
        let physicalParent = base.appendingPathComponent("physical")
        let project = physicalParent.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let logicalParent = base.appendingPathComponent("logical")
        try FileManager.default.createSymbolicLink(at: logicalParent, withDestinationURL: physicalParent)

        let physical = project.resolvingSymlinksInPath().standardizedFileURL.path
        let logical = logicalParent.appendingPathComponent("proj").path
        return (physical, logical, { try? FileManager.default.removeItem(at: base) })
    }

    @Test("returns the logical alias when PWD is a symlink of the physical path")
    func returnsLogicalAlias() throws {
        let (physical, logical, cleanup) = try makeSymlink()
        defer { cleanup() }

        let aliases = ClaudeProjectAliasResolver.aliasPaths(
            forPhysicalPath: physical,
            environment: ["PWD": logical]
        )
        #expect(aliases == [logical])
    }

    @Test("returns nothing when PWD equals the physical path")
    func noAliasWhenPwdIsPhysical() throws {
        let (physical, _, cleanup) = try makeSymlink()
        defer { cleanup() }

        let aliases = ClaudeProjectAliasResolver.aliasPaths(
            forPhysicalPath: physical,
            environment: ["PWD": physical]
        )
        #expect(aliases.isEmpty)
    }

    @Test("returns nothing when PWD is an unrelated directory")
    func noAliasForUnrelatedPwd() throws {
        let (physical, _, cleanup) = try makeSymlink()
        defer { cleanup() }

        let aliases = ClaudeProjectAliasResolver.aliasPaths(
            forPhysicalPath: physical,
            environment: ["PWD": "/some/other/place"]
        )
        #expect(aliases.isEmpty)
    }

    @Test("returns nothing when PWD is absent")
    func noAliasWhenPwdMissing() throws {
        let (physical, _, cleanup) = try makeSymlink()
        defer { cleanup() }

        let aliases = ClaudeProjectAliasResolver.aliasPaths(
            forPhysicalPath: physical,
            environment: [:]
        )
        #expect(aliases.isEmpty)
    }
}
