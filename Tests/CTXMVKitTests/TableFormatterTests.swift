@testable import CTXMVKit
import Foundation
import Testing

@Suite("Verifies table layout, padding, and separator width calculations.")
struct TableFormatterTests {
    static let columns: [TableColumn] = [
        TableColumn(title: "NAME", width: 10),
        TableColumn(title: "AGE", width: 5),
        TableColumn(title: "CITY", width: 12, gap: 0),
    ]
    static let formatter = TableFormatter(columns: columns)

    @Test("header pads columns to defined widths")
    func headerAlignment() {
        let header = Self.formatter.formatHeader()
        // NAME(10) + gap(2) + AGE(5) + gap(2) + CITY(12)
        #expect(header == "NAME        AGE    CITY        ")
    }

    @Test("row pads values to match header")
    func rowAlignment() {
        let row = Self.formatter.formatRow(["Alice", "30", "Tokyo"])
        #expect(row == "Alice       30     Tokyo       ")
    }

    @Test("row truncates long values at column width")
    func longValueNotTruncatedByFormatter() {
        // TableFormatter pads but does NOT truncate; callers are responsible for truncation
        let row = Self.formatter.formatRow(["VeryLongNameHere", "30", "X"])
        #expect(row.hasPrefix("VeryLongNameHere"))
    }

    @Test("missing values treated as empty")
    func missingValues() {
        let row = Self.formatter.formatRow(["Only"])
        #expect(row.hasPrefix("Only"))
        // AGE and CITY columns should still be padded
        #expect(row.contains("     "))
    }

    @Test("separator matches total width")
    func separatorWidth() {
        let sep = Self.formatter.formatSeparator()
        let expectedWidth = Self.formatter.totalWidth
        #expect(sep.count == expectedWidth)
        #expect(sep.allSatisfy { $0 == "-" })
    }

    @Test("header and row have same effective width for equal-length values")
    func headerRowWidthConsistency() {
        let header = Self.formatter.formatHeader()
        let row = Self.formatter.formatRow(["1234567890", "12345", "123456789012"])
        // When values exactly fill column width, header and row should have same length
        #expect(header.count == row.count)
    }

    @Test("totalWidth calculation")
    func totalWidth() {
        // NAME(10) + gap(2) + AGE(5) + gap(2) + CITY(12) + gap(0) = 31
        #expect(Self.formatter.totalWidth == 31)
    }
}

@Suite("Verifies the row values prepared for list command table output.")
struct ListRunnerRowValuesTests {
    @Test("produces correct number of columns")
    func columnCount() {
        let summary = SessionSummary(
            id: "abc12345-6789-0000-1111-222233334444",
            source: .codex,
            projectPath: "/test/project",
            createdAt: Date(timeIntervalSince1970: 1_710_000_000),
            lastMessageAt: Date(timeIntervalSince1970: 1_710_100_000),
            model: nil,
            messageCount: 5,
            lastUserMessage: "hello world",
            byteSize: 1536
        )
        let values = ListRunner.rowValues(for: summary)
        #expect(values.count == 6)
        #expect(values[0] == "codex")
        #expect(values[1] == "33334444") // suffix(8) of the id
        #expect(values[2] == "1.5 KB")
        #expect(values[5] == "hello world")
    }

    private struct DateColumnScenario: CustomTestStringConvertible, Sendable {
        var testDescription: String { name }

        let name: String
        let source: AgentSource
        let created: Date
        let lastMessageAt: Date?
        let expectedDateForColumn: Date
    }

    private static let dateColumnScenarios: [DateColumnScenario] = {
        let created = Date(timeIntervalSince1970: 1_710_000_000)
        let lastMsg = Date(timeIntervalSince1970: 1_710_100_000)
        return [
            DateColumnScenario(
                name: "uses lastMessageAt for date when available",
                source: .claudeCode,
                created: created,
                lastMessageAt: lastMsg,
                expectedDateForColumn: lastMsg
            ),
            DateColumnScenario(
                name: "falls back to createdAt when lastMessageAt is nil",
                source: .cursor,
                created: created,
                lastMessageAt: nil,
                expectedDateForColumn: created
            ),
        ]
    }()

    @Test("date column prefers lastMessageAt or createdAt", arguments: dateColumnScenarios)
    private func listDateColumn(_ scenario: DateColumnScenario) {
        let summary = SessionSummary(
            id: "test-id-suffix12",
            source: scenario.source,
            projectPath: nil,
            createdAt: scenario.created,
            lastMessageAt: scenario.lastMessageAt,
            model: nil,
            messageCount: 0,
            lastUserMessage: nil
        )
        let values = ListRunner.rowValues(for: summary)
        let dateStr = DateUtils.dateTimeShort.string(from: scenario.expectedDateForColumn)
        #expect(values[3] == dateStr)
    }

    @Test("observer session appends [obs] to source")
    func observerLabel() {
        let summary = SessionSummary(
            id: "obs-session-12345678",
            source: .claudeCode,
            projectPath: nil,
            createdAt: Date(),
            model: nil,
            messageCount: 0,
            lastUserMessage: nil,
            isObserverSession: true
        )
        let values = ListRunner.rowValues(for: summary)
        #expect(values[0] == "claude-code [obs]")
    }

    @Test("nil lastUserMessage shows dash")
    func nilMessage() {
        let summary = SessionSummary(
            id: "test-id-12345678",
            source: .codex,
            projectPath: nil,
            createdAt: Date(),
            model: nil,
            messageCount: 0,
            lastUserMessage: nil
        )
        let values = ListRunner.rowValues(for: summary)
        #expect(values[5] == "-")
    }
}

@Suite("Verifies middle truncation behavior for displayed project paths.")
struct PathTruncatedTests {
    @Test("short path returned as-is")
    func shortPath() {
        let path = "/Users/example/proj"
        #expect(path.pathTruncated(to: 30) == path)
    }

    @Test("long path keeps trailing component")
    func longPathKeepsTrailing() {
        let path = "/Users/example/workspace/projects/ctxmv"
        let result = path.pathTruncated(to: 25)
        #expect(result.hasSuffix("/ctxmv"))
        #expect(result.hasPrefix("/Users/example/"))
        #expect(result.contains("..."))
        #expect(result.count <= 25)
    }

    @Test("very tight limit falls back to ellipsis + trailing")
    func tightLimit() {
        let path = "/Users/example/workspace/projects/ctxmv"
        let result = path.pathTruncated(to: 15)
        #expect(result.hasSuffix("/ctxmv"))
        #expect(result.contains("..."))
        #expect(result.count <= 15)
    }

    @Test("two-component path uses regular truncation")
    func twoComponents() {
        let path = "/VeryLongDirectoryName/file"
        let result = path.pathTruncated(to: 10)
        #expect(result.count <= 10)
        #expect(result.hasSuffix("..."))
    }

    @Test("exact fit not truncated")
    func exactFit() {
        let path = "/Users/example/project"
        #expect(path.pathTruncated(to: path.count) == path)
    }
}
