import ArgumentParser
import CTXMVKit

/// Migrates a session into another agent's native storage format.
struct MigrateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "migrate",
        abstract: "Migrate a session to another agent",
        shouldDisplay: false
    )

    @Argument(help: "Session ID to migrate")
    var sessionID: String

    @Option(name: .long, help: "Target agent: claude-code, codex, or cursor")
    var to: AgentSource

    @OptionGroup var options: GlobalOptions

    func run() async throws {
        if options.verbose { logger.logLevel = .debug }
        try await MigrateRunner(
            sessionID: sessionID,
            target: to
        ).run()
    }
}
