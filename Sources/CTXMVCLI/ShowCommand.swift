import ArgumentParser
import CTXMVKit

/// Shows messages from a single session.
struct ShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show conversation messages for a session"
    )

    @Argument(help: "Session ID (full or prefix)")
    var sessionID: String

    @Option(name: .long, help: "Restrict search to a specific source (claude-code, codex, cursor)")
    var source: AgentSource?

    @Flag(name: .long, help: "Show raw content without compacting XML-like blocks")
    var raw: Bool = false

    @Option(name: .long, help: "Maximum number of most recent messages to show")
    var limit: Int?

    @Option(name: .long, help: "Auto-limit sessions once their backing storage exceeds this many bytes")
    var largeSessionBytes: Int = 1_048_576

    @Flag(name: .long, help: "Show all messages and bypass large-session protection")
    var all: Bool = false

    @OptionGroup var options: GlobalOptions

    func run() async throws {
        if options.verbose { logger.logLevel = .debug }
        try await ShowRunner(
            sessionID: sessionID,
            source: source,
            raw: raw,
            messageLimit: all ? nil : limit.map { max($0, 1) },
            largeSessionByteThreshold: all ? nil : Int64(max(largeSessionBytes, 1))
        ).run()
    }
}
