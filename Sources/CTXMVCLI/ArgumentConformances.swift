import ArgumentParser
import CTXMVKit

/// Allows `AgentSource` to be parsed directly from command-line arguments.
extension AgentSource: @retroactive ExpressibleByArgument {}
