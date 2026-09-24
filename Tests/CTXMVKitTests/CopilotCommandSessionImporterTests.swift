@testable import CTXMVKit
import Foundation
import Testing

struct CopilotCommandSessionImporterTests {
    @Test("session imports disable remote sync")
    func importCommandKeepsSessionLocal() {
        let arguments = CopilotCommandSessionImporter.importArguments(
            transcriptURL: URL(filePath: "/synthetic/session.jsonl"),
            workingDirectory: "/synthetic/workspace",
            dryRun: true
        )

        #expect(Array(arguments.prefix(3)) == ["--no-auto-update", "--no-remote", "--no-remote-export"])
        #expect(Array(arguments[3...4]) == ["sessions", "import"])
        #expect(arguments[5] == "--dry-run")
    }

    @Test("session import disables GitHub server contact and telemetry")
    func importProcessRunsOfflineWithOnlyRequiredEnvironment() {
        let copilotHome = URL(filePath: "/synthetic/home/.copilot")
        let environment = CopilotCommandSessionImporter.processEnvironment(
            copilotHome: copilotHome,
            path: "/synthetic/bin",
            temporaryDirectory: "/synthetic/tmp"
        )

        #expect(environment == [
            "PATH": "/synthetic/bin",
            "HOME": "/synthetic/home",
            "TMPDIR": "/synthetic/tmp",
            "COPILOT_HOME": "/synthetic/home/.copilot",
            "COPILOT_OFFLINE": "true",
        ])
    }

    @Test("Copilot resume hints keep migrated sessions local")
    func resumeCommandKeepsSessionLocal() {
        #expect(
            MigrateRunner.resumeCommand(for: .copilotCLI, sessionID: "synthetic-session")
                == "copilot --no-remote --no-remote-export --resume=synthetic-session"
        )
    }
}
