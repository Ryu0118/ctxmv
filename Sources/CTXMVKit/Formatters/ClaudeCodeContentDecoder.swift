import Foundation
import RegexBuilder

/// Claude Code IDE-injected XML tag names. Single source of truth; do not duplicate elsewhere.
private enum ClaudeCodeTag: String, CaseIterable, Sendable {
    case commandMessage = "command-message"
    case commandName = "command-name"
    case commandArgs = "command-args"
    case localCommandCaveat = "local-command-caveat"
    case localCommandStdout = "local-command-stdout"
    case taskNotification = "task-notification"
    case summary
    case result
}

/// Decoded output labels (SSoT). Do not duplicate string literals.
private enum ClaudeCodeDecodedLabel: String, CaseIterable, Sendable {
    case command = "[Command]"
    case localCommandOutput = "[Local command output — do not respond unless explicitly asked]"
    case stdout = "[stdout]"
    case subagent = "[Subagent]"
    case subagentNotification = "[Subagent notification]"
}

/// System-injected tag prefixes across agents (Codex, etc.). Not meaningful as first user messages.
private enum SystemNoisePrefix: String, CaseIterable, Sendable {
    case userQuery = "<user_query>"
    case userInfo = "<user_info>"
    case permissions = "<permissions "
    case agentsMd = "# AGENTS.md"
}

/// Filters system-injected noise from message previews and fallback content.
enum MessageFilter: Sendable {
    static func isNoise(_ content: String) -> Bool {
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else { return true }
        if ClaudeCodeDecodedLabel.allCases.contains(where: { trimmedContent.hasPrefix($0.rawValue) }) {
            return true
        }
        return SystemNoisePrefix.allCases.contains { trimmedContent.hasPrefix($0.rawValue) }
    }

    static func firstMeaningful(_ candidates: [String]) -> String? {
        candidates.first { !isNoise($0) }.map { String($0.prefix(200)) }
    }

    static func lastMeaningful(_ candidates: [String]) -> String? {
        candidates.last { !isNoise($0) }.map { String($0.prefix(200)) }
    }
}

/// Cached regex patterns for Claude Code XML tag matching.
private enum TagRegex {
    nonisolated(unsafe) static let taskNotification = Regex {
        "<task-notification>"
        Capture { ZeroOrMore(.any, .reluctant) }
        "</task-notification>"
    }.dotMatchesNewlines()

    nonisolated(unsafe) static let summary = Regex {
        "<summary>"
        Capture { ZeroOrMore(.any, .reluctant) }
        "</summary>"
    }.dotMatchesNewlines()

    nonisolated(unsafe) static let result = Regex {
        "<result>"
        Capture { ZeroOrMore(.any, .reluctant) }
        "</result>"
    }.dotMatchesNewlines()

    nonisolated(unsafe) static let commandMessage = Regex {
        "<command-message>"
        ZeroOrMore(.any, .reluctant)
        "</command-message>"
    }.dotMatchesNewlines()

    nonisolated(unsafe) static let commandName = Regex {
        "<command-name>"
        Capture { ZeroOrMore(.any, .reluctant) }
        "</command-name>"
    }.dotMatchesNewlines()

    nonisolated(unsafe) static let commandArgs = Regex {
        "<command-args>"
        Capture { ZeroOrMore(.any, .reluctant) }
        "</command-args>"
    }.dotMatchesNewlines()

    nonisolated(unsafe) static let localCommandCaveat = Regex {
        "<local-command-caveat>"
        ZeroOrMore(.any, .reluctant)
        "</local-command-caveat>"
    }.dotMatchesNewlines()

    nonisolated(unsafe) static let localCommandStdout = Regex {
        "<local-command-stdout>"
        Capture { ZeroOrMore(.any, .reluctant) }
        "</local-command-stdout>"
    }.dotMatchesNewlines()
}

/// Decodes Claude Code's internal XML structures into AI-friendly plain text.
/// Only known IDE-injected tags are transformed; other content is left unchanged.
enum ClaudeCodeContentDecoder: Sendable {
    static func decode(_ content: String) -> String {
        var result = content
        result = decodeTaskNotification(result)
        result = decodeCommandBlock(result)
        result = decodeLocalCommandCaveat(result)
        result = decodeLocalCommandStdout(result)
        return result
    }

    private static func decodeTaskNotification(_ text: String) -> String {
        var result = text
        for match in text.matches(of: TagRegex.taskNotification).reversed() {
            let full = String(match.output.1)
            let summary = full.firstMatch(of: TagRegex.summary)
                .map { String($0.output.1).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            let resultContent = full.firstMatch(of: TagRegex.result)
                .map { String($0.output.1).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""

            let decoded: String
            switch (summary.isEmpty, resultContent.isEmpty) {
            case (true, true):
                decoded = ClaudeCodeDecodedLabel.subagentNotification.rawValue
            case (true, false):
                decoded = "\(ClaudeCodeDecodedLabel.subagent.rawValue)\n\n\(resultContent)"
            case (false, true):
                decoded = "\(ClaudeCodeDecodedLabel.subagent.rawValue) \(summary)"
            case (false, false):
                decoded = "\(ClaudeCodeDecodedLabel.subagent.rawValue) \(summary)\n\n\(resultContent)"
            }
            result.replaceSubrange(match.range, with: decoded)
        }
        return result
    }

    private static func decodeCommandBlock(_ text: String) -> String {
        guard let nameMatch = text.firstMatch(of: TagRegex.commandName) else { return text }
        let name = String(nameMatch.output.1).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return text }

        let args = text.firstMatch(of: TagRegex.commandArgs)
            .map { String($0.output.1).trimmingCharacters(in: .whitespaces) }
        let label = ClaudeCodeDecodedLabel.command.rawValue
        let decoded = args.map { "\(label) \(name) \($0)" } ?? "\(label) \(name)"

        var result = text.replacing(TagRegex.commandMessage, with: "")
        result = result.replacing(TagRegex.commandName, with: "")
        result = result.replacing(TagRegex.commandArgs, with: "")

        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? decoded : "\(decoded)\n\n\(trimmed)"
    }

    private static func decodeLocalCommandCaveat(_ text: String) -> String {
        text.replacing(TagRegex.localCommandCaveat, with: ClaudeCodeDecodedLabel.localCommandOutput.rawValue)
    }

    private static func decodeLocalCommandStdout(_ text: String) -> String {
        text.replacing(TagRegex.localCommandStdout) { match in
            "\(ClaudeCodeDecodedLabel.stdout.rawValue)\n\(match.output.1)"
        }
    }
}
