@testable import CTXMVKit
import Foundation
import Testing

@Suite("Verifies project-path recovery heuristics from Cursor transcript contents.")
struct CursorTranscriptProjectPathResolverTests {
    @Test("prefers working_directory from transcript metadata")
    func resolvesWorkingDirectory() {
        let fileSystem = MockFileManager()
        let projectPath = "/Users/tester/workspaces/sample-project"
        let transcriptFile = URL(fileURLWithPath: "/Users/tester/.cursor/projects/workspace/agent-transcripts/session.jsonl")
        let resolver = CursorTranscriptProjectPathResolver(fileSystem: fileSystem)

        fileSystem.directories[projectPath] = []
        fileSystem.files[transcriptFile.path] = #"""
        {"role":"assistant","message":{"content":[{"type":"tool_use","name":"Shell","input":{"command":"swift test","working_directory":"\#(projectPath)"}}]}}
        """#.data(using: .utf8)!

        #expect(resolver.resolveProjectPath(for: transcriptFile) == projectPath)
    }

    @Test("falls back to decoded workspace path when transcript only contains file paths")
    func fallsBackToWorkspacePath() {
        let fileSystem = MockFileManager()
        let workspacePath = "/Users/tester/workspaces/library/example"
        let transcriptFile = URL(fileURLWithPath: "/Users/tester/.cursor/projects/Users-tester-workspaces-library-example/agent-transcripts/session/session.jsonl")
        let resolver = CursorTranscriptProjectPathResolver(fileSystem: fileSystem)

        fileSystem.files[transcriptFile.path] = #"""
        {"role":"assistant","message":{"content":[{"type":"tool_use","name":"ReadFile","input":{"path":"\#(workspacePath)/Package.swift"}}]}}
        """#.data(using: .utf8)!

        #expect(resolver.resolveProjectPath(for: transcriptFile) == workspacePath)
    }

    @Test("returns a standardized working directory path")
    func standardizesWorkingDirectory() {
        let fileSystem = MockFileManager()
        let standardizedPath = "/Users/tester/workspaces/sample-project"
        let nonStandardizedPath = "/Users/tester/workspaces/tmp/../sample-project"
        let transcriptFile = URL(fileURLWithPath: "/Users/tester/.cursor/projects/workspace/agent-transcripts/session.jsonl")
        let resolver = CursorTranscriptProjectPathResolver(fileSystem: fileSystem)

        fileSystem.directories[standardizedPath] = []
        fileSystem.files[transcriptFile.path] = #"""
        {"role":"assistant","message":{"content":[{"type":"tool_use","name":"Shell","input":{"command":"swift test","working_directory":"\#(nonStandardizedPath)"}}]}}
        """#.data(using: .utf8)!

        #expect(resolver.resolveProjectPath(for: transcriptFile) == standardizedPath)
    }
}
