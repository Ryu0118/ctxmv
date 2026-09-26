import ArgumentParser
import CTXMVKit

/// Allows `AgentSource` to be parsed directly from command-line arguments.
extension AgentSource: @retroactive ExpressibleByArgument {}

/// Allows only writable agent destinations to be parsed from command-line arguments.
extension MigrationTarget: ExpressibleByArgument {}
