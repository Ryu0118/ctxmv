import ArgumentParser
import CTXMVKit

/// Migrates a session into another agent's storage format.
struct MigrateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "migrate",
        abstract: "Migrate a session to another agent",
        shouldDisplay: false
    )

    @Argument(help: "Session ID to migrate")
    var sessionID: String

    @Option(name: .customLong("to"), help: "Target agent: \(MigrationTarget.allCases.map(\.rawValue).joined(separator: ", "))")
    var target: MigrationTarget

    @Option(name: .customLong("from"), help: "Source agent: \(AgentSource.allCases.map(\.rawValue).joined(separator: ", "))")
    var source: AgentSource?

    @OptionGroup var options: GlobalOptions

    func run() async throws {
        if options.verbose { logger.logLevel = .debug }
        try await MigrateRunner(
            sessionID: sessionID,
            target: target,
            source: source
        ).run()
    }
}
