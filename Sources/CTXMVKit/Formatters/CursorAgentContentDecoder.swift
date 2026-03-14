import Foundation
import RegexBuilder

/// Cursor agent-transcript tag names handled by the decoder and writer.
enum CursorAgentTag: String, CaseIterable, Sendable {
    case userQuery = "user_query"

    var openingTag: String { "<\(rawValue)>" }
    var closingTag: String { "</\(rawValue)>" }

    func wrap(_ content: String) -> String {
        "\(openingTag)\n\(content)\n\(closingTag)"
    }
}

private enum CursorTagRegex {
    nonisolated(unsafe) static let wholeUserQuery = Regex {
        Anchor.startOfSubject
        ZeroOrMore(.whitespace)
        CursorAgentTag.userQuery.openingTag
        Capture { ZeroOrMore(.any, .reluctant) }
        CursorAgentTag.userQuery.closingTag
        ZeroOrMore(.whitespace)
        Anchor.endOfSubject
    }.dotMatchesNewlines()

    nonisolated(unsafe) static let userQuery = Regex {
        CursorAgentTag.userQuery.openingTag
        Capture { ZeroOrMore(.any, .reluctant) }
        CursorAgentTag.userQuery.closingTag
    }.dotMatchesNewlines()
}

/// Decodes Cursor agent-transcript wrappers into plain text.
/// - Note: Currently we only normalize `<user_query>...</user_query>` blocks.
enum CursorAgentContentDecoder: Sendable {
    static func decode(_ content: String) -> String {
        if let whole = content.firstMatch(of: CursorTagRegex.wholeUserQuery) {
            let unwrapped = String(whole.output.1)
            return decode(unwrapped).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let matches = content.matches(of: CursorTagRegex.userQuery)
        guard !matches.isEmpty else { return content }

        var result = content
        for match in matches.reversed() {
            let decodedInner = decode(String(match.output.1)).trimmingCharacters(in: .whitespacesAndNewlines)
            result.replaceSubrange(match.range, with: decodedInner)
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
