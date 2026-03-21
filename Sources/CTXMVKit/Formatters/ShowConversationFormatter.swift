import Foundation
import Rainbow

/// Formats a conversation for the `show` command without performing any I/O.
package struct ShowConversationFormatter {
    private let raw: Bool

    package init(raw: Bool) {
        self.raw = raw
    }

    package func format(_ conversation: UnifiedConversation) -> String {
        let renderedMessages = conversation.messages.enumerated().map { messageIndex, message in
            let (label, color) = roleLabelAndColor(message.role)
            return [
                formatMessageHeader(label: label, color: color, timestamp: message.timestamp, index: messageIndex),
                formatMessageBody(message.decodedContent(for: conversation.source)),
            ].joined(separator: "\n")
        }

        guard !renderedMessages.isEmpty else {
            return buildHeader(conversation)
        }

        return [
            buildHeader(conversation),
            renderedMessages.joined(separator: "\n\n\(String(repeating: "-", count: 88))\n\n"),
        ].joined(separator: "\n\n")
    }

    private func buildHeader(_ conversation: UnifiedConversation) -> String {
        var lines = [
            "Session: \(conversation.id)".bold,
            "Source:   \(conversation.source.rawValue)\(conversation.isObserverSession ? " [observer]" : "")",
        ]
        if let project = conversation.projectPath { lines.append("Project:  \(project)") }
        lines.append("Date:     \(DateUtils.dateTimeFull.string(from: conversation.createdAt))")
        if let model = conversation.model { lines.append("Model:    \(model)") }
        lines.append("Messages: \(conversation.messages.count)")
        lines.append("View:     \(raw ? "raw" : "compact")")
        lines.append(String(repeating: "=", count: 88))
        return lines.joined(separator: "\n")
    }

    private func roleLabelAndColor(_ role: MessageRole) -> (String, NamedColor) {
        switch role {
        case .user: ("USER", .green)
        case .assistant: ("ASSISTANT", .cyan)
        case .system: ("SYSTEM", .yellow)
        case .tool: ("TOOL", .default)
        }
    }

    private func formatMessageHeader(label: String, color: NamedColor, timestamp: Date?, index: Int) -> String {
        var header = "[\(label)]"
        if let timestamp {
            header += " \(DateUtils.dateTimeFull.string(from: timestamp))"
        }
        header += "  (#\(index + 1))"
        return header.applyingColor(color)
    }

    private func formatMessageBody(_ content: String) -> String {
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let compacted = raw ? normalized : compactStructuredBlocks(in: normalized)
        return collapseBlankLines(compacted)
            .map { $0.isEmpty ? "" : "  \($0)" }
            .joined(separator: "\n")
    }

    /// Collapses repeated blank lines and trims leading/trailing empty lines so
    /// compact output reads predictably regardless of source formatting noise.
    private func collapseBlankLines(_ text: String) -> [String] {
        var collapsed: [String] = []
        var previousBlank = false

        for line in text.components(separatedBy: .newlines) {
            let isBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if isBlank {
                if !previousBlank { collapsed.append("") }
            } else {
                collapsed.append(line)
            }
            previousBlank = isBlank
        }

        while collapsed.first?.isEmpty == true {
            collapsed.removeFirst()
        }
        while collapsed.last?.isEmpty == true {
            collapsed.removeLast()
        }
        return collapsed
    }

    /// Replaces large XML-looking sections with placeholders in compact mode.
    /// This keeps Claude/Cursor structured payloads readable without hiding
    /// short snippets that may still carry user-visible meaning.
    private func compactStructuredBlocks(in text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        var result: [String] = []
        var lineIndex = 0

        while lineIndex < lines.count {
            let trimmed = lines[lineIndex].trimmingCharacters(in: .whitespaces)

            if trimmed.lowercased().hasPrefix("```xml") {
                let blockStart = lineIndex
                lineIndex += 1
                while lineIndex < lines.count, lines[lineIndex].trimmingCharacters(in: .whitespaces) != "```" {
                    lineIndex += 1
                }
                result.append("[XML block omitted: \(max(0, lineIndex - blockStart - 1)) lines, use --raw to show full content]")
                if lineIndex < lines.count { lineIndex += 1 }
                continue
            }

            if isXMLTagLine(trimmed) {
                let blockStart = lineIndex
                while lineIndex < lines.count, isXMLTagLine(lines[lineIndex].trimmingCharacters(in: .whitespaces)) {
                    lineIndex += 1
                }
                let count = lineIndex - blockStart
                if count >= 3 {
                    result.append("[XML-like tag block omitted: \(count) lines, use --raw to show full content]")
                } else {
                    for sourceLineIndex in blockStart ..< lineIndex {
                        result.append(lines[sourceLineIndex])
                    }
                }
                continue
            }

            result.append(lines[lineIndex])
            lineIndex += 1
        }

        return result.joined(separator: "\n")
    }

    /// Uses a deliberately simple heuristic because these blocks are only for
    /// display compaction, not for XML parsing correctness.
    private func isXMLTagLine(_ line: String) -> Bool {
        !line.isEmpty && line.hasPrefix("<") && line.hasSuffix(">")
    }
}
