@testable import CTXMVKit
import Foundation
import Testing

@Suite
struct ClaudeProjectAliasResolverTests {
    @Test("returns the logical alias when it is a symlink of the physical path")
    func returnsLogicalAlias() throws {
        let (physical, logical, cleanup) = try TestFixtures.makeSymlinkedProject()
        defer { cleanup() }

        let alias = ClaudeProjectAliasResolver.alias(forPhysicalPath: physical, logicalCwd: logical)
        #expect(alias == logical)
    }

    @Test("returns nil when the logical cwd equals the physical path")
    func noAliasWhenLogicalIsPhysical() throws {
        let (physical, _, cleanup) = try TestFixtures.makeSymlinkedProject()
        defer { cleanup() }

        #expect(ClaudeProjectAliasResolver.alias(forPhysicalPath: physical, logicalCwd: physical) == nil)
    }

    @Test("returns nil when the logical cwd is an unrelated directory")
    func noAliasForUnrelatedCwd() throws {
        let (physical, _, cleanup) = try TestFixtures.makeSymlinkedProject()
        defer { cleanup() }

        #expect(ClaudeProjectAliasResolver.alias(forPhysicalPath: physical, logicalCwd: "/some/other/place") == nil)
    }

    @Test("returns nil when the logical cwd is absent")
    func noAliasWhenLogicalMissing() throws {
        let (physical, _, cleanup) = try TestFixtures.makeSymlinkedProject()
        defer { cleanup() }

        #expect(ClaudeProjectAliasResolver.alias(forPhysicalPath: physical, logicalCwd: nil) == nil)
    }
}
