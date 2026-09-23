@testable import CTXMVKit
import Foundation
import Testing

struct CopilotSourceMigrateRunnerTests {
    private static let sessionID = "copilot-session-fixture"
    private static let projectPath = "/test/copilot-project"
    private static let userPrompt = "Synthetic Copilot user prompt"
    private static let assistantResponse = "Synthetic Copilot assistant response"

    @Test(
        "MigrateRunner discovers Copilot CLI sessions and writes resumable targets",
        arguments: [MigrationTarget.claudeCode, .codex, .kimiCode]
    )
    func migratesCopilotSession(to target: MigrationTarget) async throws {
        let fileSystem = makeFileSystem()
        let runner = MigrateRunner(
            sessionID: Self.sessionID,
            target: target,
            source: .copilotCLI,
            fileSystem: fileSystem,
            sqlite: MockSQLiteReader()
        )

        try await runner.run()

        let destination = try #require(fileSystem.files.first { path, _ in
            switch target {
            case .claudeCode:
                path.contains("/.claude/projects/") && path.hasSuffix(".jsonl")
            case .codex:
                path.contains("/.codex/sessions/") && path.hasSuffix(".jsonl")
            case .kimiCode:
                path.hasSuffix("/agents/main/wire.jsonl")
            case .cursor:
                false
            }
        })
        let output = try #require(String(data: destination.value, encoding: .utf8))

        #expect(output.contains(Self.userPrompt))
        #expect(output.contains(Self.assistantResponse))

        switch target {
        case .claudeCode:
            let firstEntry = try #require(output.split(separator: "\n").first)
            #expect(firstEntry.contains("\"type\":\"user\""))
            #expect(output.contains("\"model\":\"test-model\""))
        case .codex:
            #expect(output.contains("\"type\":\"response_item\""))
            #expect(output.contains("\"type\":\"event_msg\""))
        case .kimiCode:
            #expect(output.contains("context.append_message"))
            #expect(output.contains("context.append_loop_event"))
        case .cursor:
            Issue.record("Unexpected migration target: \(target.rawValue)")
        }
    }

    private func makeFileSystem() -> MockFileManager {
        let fileSystem = MockFileManager()
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        fileSystem.homeDirectoryForCurrentUser = home

        let sessionsDirectory = home
            .appendingPathComponent(".copilot", isDirectory: true)
            .appendingPathComponent("session-state", isDirectory: true)
        let sessionDirectory = sessionsDirectory.appendingPathComponent(Self.sessionID, isDirectory: true)
        let eventsFile = sessionDirectory.appendingPathComponent("events.jsonl")
        let workspaceFile = sessionDirectory.appendingPathComponent("workspace.yaml")

        fileSystem.directories[sessionsDirectory.path] = [sessionDirectory]
        fileSystem.directories[sessionDirectory.path] = []
        fileSystem.files[eventsFile.path] = Data(
            """
            {"type":"user.message","timestamp":"2025-01-02T03:04:05.000Z","data":{"content":"\(Self.userPrompt)"}}
            {"type":"assistant.message","timestamp":"2025-01-02T03:04:10.000Z","data":{"content":"\(Self.assistantResponse)","model":"test-model"}}
            """.utf8
        )
        fileSystem.files[workspaceFile.path] = Data("cwd: \(Self.projectPath)\n".utf8)
        return fileSystem
    }
}
