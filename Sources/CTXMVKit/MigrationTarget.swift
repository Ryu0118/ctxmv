/// Agents ctxmv can write migrated sessions to.
package enum MigrationTarget: String, CaseIterable, Sendable {
    case claudeCode = "claude-code"
    case codex
    case cursor
    case kimiCode = "kimi-code"
    case copilotCLI = "copilot-cli"
}
