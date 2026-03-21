@testable import CTXMVKit
import Foundation
import Testing

@Suite
struct ProjectPathResolverTests {
    // MARK: - Encoding

    @Test("encodedClaudeProjectPath matches ClaudeCodeMigrator-style collision")
    func encodingCollisionExample() {
        let hyphenated = "/Users/example/acme/foo-bar-baz"
        let nested = "/Users/example/acme/foo/bar/baz"
        let encH = ProjectPathResolver.encodedClaudeProjectPath(hyphenated)
        let encN = ProjectPathResolver.encodedClaudeProjectPath(nested)
        #expect(encH == encN)
        #expect(encH == "-Users-example-acme-foo-bar-baz")
    }

    @Test("DFS finds at least two component lists for a nontrivial collision string")
    func enumeratesMultipleDecodings() {
        let encoded = "-Users-example-acme-foo-bar-baz"
        let lists = ProjectPathResolver.allPathComponentLists(encoded: encoded)
        #expect(lists.count >= 2)
        let joined = lists
            .map { "/" + $0.joined(separator: "/") }
            .map { ProjectPathResolver.encodedClaudeProjectPath($0) }
        #expect(joined.allSatisfy { $0 == encoded })
    }

    // MARK: - cdPath (JSONL-path-based resolution)

    @Test("prefers existing directory among colliding spellings")
    func picksExistingDirectory() {
        let fileSystem = MockFileManager()
        let hyphenated = "/Users/example/acme/foo-bar-baz"
        let wrongNested = "/Users/example/acme/foo/bar/baz"
        fileSystem.directories[hyphenated] = []

        let jsonl = "/mock/home/.claude/projects/-Users-example-acme-foo-bar-baz/sess.jsonl"
        let resolved = ProjectPathResolver.cdPath(
            forStoredProjectPath: wrongNested,
            writtenJSONLPath: jsonl,
            fileSystem: fileSystem
        )
        #expect(resolved == URL(fileURLWithPath: hyphenated).standardizedFileURL.path)
    }

    @Test("returns stored path when it exists and matches the written bucket")
    func prefersStoredWhenValid() {
        let fileSystem = MockFileManager()
        let path = "/tmp/resume-hint-target-dir"
        fileSystem.directories[path] = []
        let enc = ProjectPathResolver.encodedClaudeProjectPath(path)
        let jsonl = "/mock/.claude/projects/\(enc)/x.jsonl"
        let resolved = ProjectPathResolver.cdPath(
            forStoredProjectPath: path,
            writtenJSONLPath: jsonl,
            fileSystem: fileSystem
        )
        #expect(resolved == URL(fileURLWithPath: path).standardizedFileURL.path)
    }

    @Test("falls back to stored string when no candidate directory exists")
    func fallsBackToStoredWhenNothingExists() {
        let fileSystem = MockFileManager()
        let wrongNested = "/Users/example/acme/foo/bar/baz"
        let jsonl = "/mock/home/.claude/projects/-Users-example-acme-foo-bar-baz/sess.jsonl"
        let resolved = ProjectPathResolver.cdPath(
            forStoredProjectPath: wrongNested,
            writtenJSONLPath: jsonl,
            fileSystem: fileSystem
        )
        #expect(resolved == wrongNested)
    }

    // MARK: - resolveProjectPath (standalone resolution without JSONL path)

    @Test("resolveProjectPath returns path as-is when it exists on disk")
    func resolveReturnsExistingPath() {
        let fileSystem = MockFileManager()
        let path = "/Users/example/workspace/my-project"
        fileSystem.directories[path] = []
        let resolved = ProjectPathResolver.resolveProjectPath(path, fileSystem: fileSystem)
        #expect(resolved == path)
    }

    @Test("resolveProjectPath finds real directory when stored path is wrong due to lossy encoding")
    func resolveFindsCorrectHyphenatedPath() {
        let fileSystem = MockFileManager()
        let wrongNested = "/Users/example/acme/foo/bar/baz"
        let realHyphenated = "/Users/example/acme/foo-bar-baz"
        fileSystem.directories[realHyphenated] = []

        let resolved = ProjectPathResolver.resolveProjectPath(wrongNested, fileSystem: fileSystem)
        #expect(resolved == URL(fileURLWithPath: realHyphenated).standardizedFileURL.path)
    }

    @Test("resolveProjectPath returns original path when no candidate exists")
    func resolveFallsBackToOriginal() {
        let fileSystem = MockFileManager()
        let nonexistent = "/Users/example/acme/foo/bar/baz"
        let resolved = ProjectPathResolver.resolveProjectPath(nonexistent, fileSystem: fileSystem)
        #expect(resolved == nonexistent)
    }

    @Test("resolveProjectPath returns nil for nil or empty input", arguments: [nil, ""] as [String?])
    func resolveReturnsNilForNilOrEmpty(input: String?) {
        let fileSystem = MockFileManager()
        let resolved = ProjectPathResolver.resolveProjectPath(input, fileSystem: fileSystem)
        #expect(resolved == nil)
    }
}
