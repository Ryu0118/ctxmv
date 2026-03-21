import Foundation

/// Column definition for table formatting.
package struct TableColumn: Sendable {
    let title: String
    let width: Int
    /// Gap (number of spaces) after this column. Last column has no gap.
    let gap: Int

    package init(title: String, width: Int, gap: Int = 2) {
        self.title = title
        self.width = width
        self.gap = gap
    }
}

/// Formats tabular data with consistent column alignment.
package struct TableFormatter: Sendable {
    let columns: [TableColumn]

    package init(columns: [TableColumn]) {
        self.columns = columns
    }

    /// Format header row, padded to match column widths.
    package func formatHeader() -> String {
        columns.enumerated().map { index, col in
            let padded = pad(col.title, width: col.width)
            return index < columns.count - 1 ? padded + String(repeating: " ", count: col.gap) : padded
        }.joined()
    }

    /// Format a data row from cell values. Values beyond column count are ignored.
    package func formatRow(_ values: [String]) -> String {
        columns.enumerated().map { index, col in
            let value = index < values.count ? values[index] : ""
            let padded = pad(value, width: col.width)
            return index < columns.count - 1 ? padded + String(repeating: " ", count: col.gap) : padded
        }.joined()
    }

    /// Total width including gaps (for separator line).
    package var totalWidth: Int {
        columns.reduce(0) { sum, col in sum + col.width + col.gap }
            - (columns.last?.gap ?? 0) // last column has no trailing gap
    }

    /// Format separator line.
    package func formatSeparator(character: Character = "-") -> String {
        String(repeating: character, count: totalWidth)
    }

    private func pad(_ text: String, width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }
}
