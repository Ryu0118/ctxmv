import Foundation

/// Describes the files written by a successful migration.
enum MigrationResult: Sendable {
    case written(path: String, sessionID: String)
}

/// Migrates a unified conversation into a target agent's storage format.
protocol SessionMigrator: Sendable {
    var target: AgentSource { get }

    /// Writes session files and returns the path written.
    func migrate(_ conversation: UnifiedConversation) throws -> MigrationResult
}

/// Describes failures that can occur during session migration.
enum MigrationError: Error, CustomStringConvertible {
    case sessionEmpty
    case writeFailed(String)
    case alreadyMigrated(existingPath: String)

    var isAlreadyMigrated: Bool {
        if case .alreadyMigrated = self { return true }
        return false
    }

    var description: String {
        switch self {
        case .sessionEmpty:
            "Cannot migrate an empty conversation."
        case let .writeFailed(detail):
            "Failed to write migration file: \(detail)"
        case let .alreadyMigrated(path):
            "Already migrated to: \(path)"
        }
    }
}
