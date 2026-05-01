import Foundation
import Rainbow

/// Formats a conversation for the `show` command without performing any I/O.
package struct ShowConversationFormatter {
    private let raw: Bool

    /// Creates a formatter; pass `raw: true` to skip structured-block compaction.
    package init(raw: Bool) {
        self.raw = raw
    }

    /// Returns the full conversation rendered as a human-readable string.
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
            previousBlank = appendLine(line, to: &collapsed, previousBlank: previousBlank)
        }
        trimEdgeBlanks(from: &collapsed)
        return collapsed
    }

    /// Appends one line to the accumulator, skipping consecutive blank lines.
    /// Returns whether the appended line was blank.
    private func appendLine(_ line: String, to collapsed: inout [String], previousBlank: Bool) -> Bool {
        let isBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
        if isBlank {
            if !previousBlank { collapsed.append("") }
        } else {
            collapsed.append(line)
        }
        return isBlank
    }

    /// Removes leading and trailing empty strings from the array in-place.
    private func trimEdgeBlanks(from lines: inout [String]) {
        while lines.first?.isEmpty == true {
            lines.removeFirst()
        }
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
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
                lineIndex = consumeCodeFence(lines: lines, from: lineIndex, into: &result)
                continue
            }

            if isXMLTagLine(trimmed) {
                lineIndex = consumeXMLTagBlock(lines: lines, from: lineIndex, into: &result)
                continue
            }

            result.append(lines[lineIndex])
            lineIndex += 1
        }

        return result.joined(separator: "\n")
    }

    /// Advances past a ` ```xml … ``` ` fence and appends a placeholder to `result`.
    /// Returns the next line index to process.
    private func consumeCodeFence(lines: [String], from start: Int, into result: inout [String]) -> Int {
        var index = start + 1
        while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces) != "```" {
            index += 1
        }
        result.append("[XML block omitted: \(max(0, index - start - 1)) lines, use --raw to show full content]")
        if index < lines.count { index += 1 }
        return index
    }

    /// Advances past a run of XML-tag lines and either omits or preserves them.
    /// Returns the next line index to process.
    private func consumeXMLTagBlock(lines: [String], from start: Int, into result: inout [String]) -> Int {
        var index = start
        while index < lines.count, isXMLTagLine(lines[index].trimmingCharacters(in: .whitespaces)) {
            index += 1
        }
        let count = index - start
        if count >= 3 {
            result.append("[XML-like tag block omitted: \(count) lines, use --raw to show full content]")
        } else {
            result.append(contentsOf: lines[start ..< index])
        }
        return index
    }

    /// Uses a deliberately simple heuristic because these blocks are only for
    /// display compaction, not for XML parsing correctness.
    private func isXMLTagLine(_ line: String) -> Bool {
        !line.isEmpty && line.hasPrefix("<") && line.hasSuffix(">")
    }
}
