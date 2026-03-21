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

    static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func encodeLine(_ value: some Encodable) -> String? {
        guard let data = try? jsonEncoder.encode(value),
              let encodedLine = String(data: data, encoding: .utf8) else { return nil }
        return encodedLine
    }
}
