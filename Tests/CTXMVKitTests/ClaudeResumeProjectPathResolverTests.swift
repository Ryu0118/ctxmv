@testable import CTXMVKit
import Foundation
import Testing

struct ClaudeResumeProjectPathResolverTests {
    @Test("encodedClaudeProjectPath matches ClaudeCodeMigrator-style collision")
    func encodingCollisionExample() {
        let hyphenated = "/Users/example/acme/foo-bar-baz"
        let nested = "/Users/example/acme/foo/bar/baz"
        let encH = ClaudeResumeProjectPathResolver.encodedClaudeProjectPath(hyphenated)
        let encN = ClaudeResumeProjectPathResolver.encodedClaudeProjectPath(nested)
        #expect(encH == encN)
        #expect(encH == "-Users-example-acme-foo-bar-baz")
    }

    @Test("DFS finds at least two component lists for a nontrivial collision string")
    func enumeratesMultipleDecodings() {
        let encoded = "-Users-example-acme-foo-bar-baz"
        let lists = ClaudeResumeProjectPathResolver.allPathComponentLists(encoded: encoded)
        #expect(lists.count >= 2)
        let joined = lists
            .map { "/" + $0.joined(separator: "/") }
            .map { ClaudeResumeProjectPathResolver.encodedClaudeProjectPath($0) }
        #expect(joined.allSatisfy { $0 == encoded })
    }

    @Test("prefers existing directory among colliding spellings")
    func picksExistingDirectory() {
        let fileSystem = MockFileManager()
        let hyphenated = "/Users/example/acme/foo-bar-baz"
        let wrongNested = "/Users/example/acme/foo/bar/baz"
        fileSystem.directories[hyphenated] = []

        let jsonl = "/mock/home/.claude/projects/-Users-example-acme-foo-bar-baz/sess.jsonl"
        let resolved = ClaudeResumeProjectPathResolver.cdPath(
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
        let enc = ClaudeResumeProjectPathResolver.encodedClaudeProjectPath(path)
        let jsonl = "/mock/.claude/projects/\(enc)/x.jsonl"
        let resolved = ClaudeResumeProjectPathResolver.cdPath(
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
        let resolved = ClaudeResumeProjectPathResolver.cdPath(
            forStoredProjectPath: wrongNested,
            writtenJSONLPath: jsonl,
            fileSystem: fileSystem
        )
        #expect(resolved == wrongNested)
    }
}
