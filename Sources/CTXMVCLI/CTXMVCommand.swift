import ArgumentParser
import CTXMVKit
import Logging

/// Global options shared across subcommands.
struct GlobalOptions: ParsableArguments {
    @Flag(name: .shortAndLong, help: "Enable verbose output")
    var verbose: Bool = false
}

/// Root command for the `ctxmv` CLI.
@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
public struct CTXMVCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "ctxmv",
        abstract: "Migrate sessions between AI coding agents",
        discussion: """
        Default action (no subcommand): migrate a session.
        Example: ctxmv <session-id> --to <claude-code|codex|cursor>
        """,
        subcommands: [MigrateCommand.self, ListCommand.self, ShowCommand.self],
        defaultSubcommand: MigrateCommand.self
    )

    public init() {}
}
