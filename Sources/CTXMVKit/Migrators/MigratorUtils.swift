import Foundation

/// Provides shared encoding and hashing helpers for migrators.
enum MigratorUtils {
    nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    static let jsonDecoder = JSONDecoder()

    static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static let millisPerSecond = 1000.0

    static func epochMillis(from date: Date) -> Int {
        Int((date.timeIntervalSince1970 * millisPerSecond).rounded())
    }

    static func encodeLine(_ value: some Encodable) -> String? {
        guard let data = try? jsonEncoder.encode(value),
              let encodedLine = String(data: data, encoding: .utf8) else { return nil }
        return encodedLine
    }

    /// Claude Code `.claude/projects/<this>/` key: the absolute path with **every** character that
    /// is not an ASCII letter or digit replaced by `-`. This mirrors Claude Code's own encoding
    /// (`path.replace(/[^a-zA-Z0-9]/g, '-')`), which collapses `/`, `_`, `.`, spaces, etc. all to
    /// `-` — e.g. `/Users/u/web_root/a.b` → `-Users-u-web-root-a-b`. Replacing only `/` writes
    /// the session into a bucket Claude never reads, so it must match byte-for-byte.
    static func encodedClaudeProjectPath(_ absolutePath: String) -> String {
        String(absolutePath.map { isClaudeProjectPathSafe($0) ? $0 : "-" })
    }

    static func isClaudeProjectPathSafe(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber)
    }
}
