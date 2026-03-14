import Foundation

/// Shared date parsing utilities
enum DateUtils: Sendable {
    private nonisolated(unsafe) static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated(unsafe) static let iso8601FallbackFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Parse an ISO 8601 date string, trying fractional seconds first
    static func parseISO8601(_ string: String) -> Date? {
        if let date = iso8601Formatter.date(from: string) {
            return date
        }
        return iso8601FallbackFormatter.date(from: string)
    }

    /// "yyyy-MM-dd"
    static let dateOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    /// "yyyy-MM-dd HH:mm"
    static let dateTimeShort: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    /// "yyyy-MM-dd HH:mm:ss"
    static let dateTimeFull: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone.current
        return formatter
    }()
}
