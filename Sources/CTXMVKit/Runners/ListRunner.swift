import Foundation
import Logging
import Rainbow

/// Lists sessions across all providers, applying optional filters, and prints the result.
package struct ListRunner: Sendable {
    private let source: AgentSource?
    private let project: String?
    private let excludeObserver: Bool
    private let limit: Int

    private let providers: [SessionProvider]

    package init(
        source: AgentSource? = nil,
        project: String? = nil,
        excludeObserver: Bool = false,
        limit: Int = 20,
        fileSystem: FileSystemProtocol = DefaultFileSystem(),
        sqlite: SQLiteProvider = DefaultSQLiteProvider()
    ) {
        self.source = source
        self.project = project
        self.excludeObserver = excludeObserver
        self.limit = limit
        providers = SessionProviderFactory.make(fileSystem: fileSystem, sqlite: sqlite)
    }

    /// Creates a runner with injected providers for tests.
    package init(
        source: AgentSource? = nil,
        project: String? = nil,
        excludeObserver: Bool = false,
        limit: Int = 20,
        providers: [SessionProvider]
    ) {
        self.source = source
        self.project = project
        self.excludeObserver = excludeObserver
        self.limit = limit
        self.providers = providers
    }

    package func run() async throws {
        let sessions = try await fetchAndFilter()
        if sessions.isEmpty {
            logger.info("No sessions found.")
            return
        }
        printTable(sessions)
    }

    /// Collects sessions from all active providers concurrently, then applies shared filters.
    private func fetchAndFilter() async throws -> [SessionSummary] {
        logger.debug("Listing sessions from \(providers.count) providers")

        let sessions = await withTaskGroup(of: [SessionSummary].self, returning: [SessionSummary].self) { group in
            for provider in activeProviders() {
                group.addTask {
                    (try? await provider.listSessions()) ?? []
                }
            }
            var all: [SessionSummary] = []
            for await batch in group {
                all.append(contentsOf: batch)
            }
            return all
        }

        return finalize(filteredSessions(from: sessions))
    }

    private func activeProviders() -> [SessionProvider] {
        guard let source else { return providers }
        return providers.filter { $0.source == source }
    }

    private func filteredSessions(from sessions: [SessionSummary]) -> [SessionSummary] {
        sessions.filter { session in
            matchesProjectFilter(session) && matchesObserverFilter(session)
        }
    }

    private func matchesProjectFilter(_ session: SessionSummary) -> Bool {
        guard let project else { return true }
        return session.projectPath?.localizedCaseInsensitiveContains(project) == true
    }

    private func matchesObserverFilter(_ session: SessionSummary) -> Bool {
        !excludeObserver || !session.isObserverSession
    }

    /// Sorts by most recent activity and applies the caller's hard limit.
    private func finalize(_ sessions: [SessionSummary]) -> [SessionSummary] {
        let sorted = sessions.sorted {
            ($0.lastMessageAt ?? $0.createdAt) > ($1.lastMessageAt ?? $1.createdAt)
        }
        guard limit > 0 else { return sorted }
        return Array(sorted.prefix(limit))
    }

    private static let tableFormatter = TableFormatter(columns: [
        TableColumn(title: "SOURCE", width: 16),
        TableColumn(title: "SESSION", width: 12),
        TableColumn(title: "SIZE", width: 8),
        TableColumn(title: "LAST MESSAGE", width: 18),
        TableColumn(title: "PROJECT", width: 28),
        TableColumn(title: "LAST PROMPT", width: 42, gap: 0),
    ])

    private func printTable(_ sessions: [SessionSummary]) {
        let tableFormatter = Self.tableFormatter
        logger.info("\(tableFormatter.formatHeader().bold)")
        logger.info("\(tableFormatter.formatSeparator())")

        for session in sessions {
            logger.info("\(formatRow(session, formatter: tableFormatter))")
        }

        logger.info("\n\(sessions.count) session(s) shown.")
    }

    package static func rowValues(for session: SessionSummary) -> [String] {
        let sourceLabel = session.source.rawValue + (session.isObserverSession ? " [obs]" : "")
        let shortSessionId = String(session.id.suffix(8))
        let size = session.byteSize.map { $0.formattedByteCount() } ?? "-"
        let displayDate = session.lastMessageAt ?? session.createdAt
        let date = DateUtils.dateTimeShort.string(from: displayDate)
        let projectPath = (session.projectPath ?? "-").pathTruncated(to: 26)
        let lastUserMessage = (session.lastUserMessage?.replacingOccurrences(of: "\n", with: " ") ?? "-").truncated(to: 42)
        return [sourceLabel, shortSessionId, size, date, projectPath, lastUserMessage]
    }

    /// Recolors only the source column so ANSI codes do not disturb downstream table alignment.
    private func formatRow(_ session: SessionSummary, formatter: TableFormatter) -> String {
        let values = Self.rowValues(for: session)
        let formattedRow = formatter.formatRow(values)
        // Apply color to the source portion only
        let coloredSource = values[0].applyingColor(colorForSource(session.source))
        let srcWidth = formatter.columns[0].width + formatter.columns[0].gap
        let rowSuffix = String(formattedRow.dropFirst(srcWidth))
        let paddedSource = coloredSource + String(repeating: " ", count: max(0, srcWidth - values[0].count))
        return paddedSource + rowSuffix
    }

    private func colorForSource(_ source: AgentSource) -> NamedColor {
        switch source {
        case .claudeCode: .cyan
        case .codex: .green
        case .cursor: .magenta
        }
    }
}
