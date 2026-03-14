import Foundation

/// Builds session summaries concurrently from a collection of inputs.
enum SessionSummaryCollector {
    static func collect<Item: Sendable>(
        _ items: [Item],
        build: @escaping @Sendable (Item) throws -> SessionSummary
    ) async -> [SessionSummary] {
        await withTaskGroup(of: SessionSummary?.self, returning: [SessionSummary].self) { group in
            for item in items {
                group.addTask {
                    try? build(item)
                }
            }

            var results: [SessionSummary] = []
            for await result in group {
                if let result {
                    results.append(result)
                }
            }
            return results
        }
    }
}
