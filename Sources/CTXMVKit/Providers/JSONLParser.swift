import Foundation

/// Shared JSONL parsing — both Claude Code and Codex use JSONL, so factor out common logic
struct JSONLParser: Sendable {
    private static let decoder = JSONDecoder()

    /// Decode a single JSONL line into a Codable type, returning nil for blank/invalid lines
    static func decodeLine<T: Decodable>(_ line: String, as type: T.Type) -> T? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    /// Decode all lines of a JSONL string into an array of Codable values
    static func decodeLines<T: Decodable>(_ text: String, as type: T.Type) -> [T] {
        text.components(separatedBy: .newlines)
            .compactMap { decodeLine($0, as: type) }
    }
}
