import ArgumentParser
import CTXMVKit

/// Lists sessions across supported providers.
struct ListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List sessions"
    )

    @Option(name: .long, help: "Filter by source (claude-code, codex, cursor)")
    var source: AgentSource?

    @Option(name: .long, help: "Filter by project path")
    var project: String?

    @Flag(name: .long, help: "Exclude claude-mem observer sessions")
    var excludeObserver: Bool = false

    @Option(name: .long, help: "Maximum number of sessions to display")
    var limit: Int = 20

    @OptionGroup var options: GlobalOptions

    func run() async throws {
        if options.verbose { logger.logLevel = .debug }
        try await ListRunner(
            source: source,
            project: project,
            excludeObserver: excludeObserver,
            limit: limit
        ).run()
    }
}
