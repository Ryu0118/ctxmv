import Foundation

/// Imports a semantic transcript through the supported Copilot CLI interface.
package protocol CopilotSessionImporter: Sendable {
    func importSession(
        semanticJSONL: String,
        workingDirectory: String,
        copilotHome: URL
    ) throws -> String
}

/// Runs `copilot sessions import` without a shell and stages transcripts with owner-only permissions.
package struct CopilotCommandSessionImporter: CopilotSessionImporter {
    private static let commandName = "copilot"
    private static let importedSessionName = "Migrated session"
    private static let minimumCLIMessage = "Install or update GitHub Copilot CLI to version 1.0.85 or newer."

    private struct ImportOutput: Decodable {
        let succeeded: Bool
        let sessionId: String?

        private enum CodingKeys: String, CodingKey {
            case succeeded = "ok"
            case sessionId
        }
    }

    package init() {}

    package func importSession(
        semanticJSONL: String,
        workingDirectory: String,
        copilotHome: URL
    ) throws -> String {
        let transcriptURL = try stage(semanticJSONL)
        defer { try? FileManager.default.removeItem(at: transcriptURL.deletingLastPathComponent()) }

        let validationArguments = Self.importArguments(
            transcriptURL: transcriptURL,
            workingDirectory: workingDirectory,
            dryRun: true
        )
        let validationOutput = try run(validationArguments, copilotHome: copilotHome)
        guard let validation = try? MigratorUtils.jsonDecoder.decode(ImportOutput.self, from: validationOutput),
              validation.succeeded else {
            throw MigrationError.writeFailed("Copilot CLI rejected the session transcript. \(Self.minimumCLIMessage)")
        }

        let output = try run(
            Self.importArguments(
                transcriptURL: transcriptURL,
                workingDirectory: workingDirectory,
                dryRun: false
            ),
            copilotHome: copilotHome
        )
        guard let result = try? MigratorUtils.jsonDecoder.decode(ImportOutput.self, from: output),
              result.succeeded,
              let sessionId = result.sessionId,
              let uuid = UUID(uuidString: sessionId) else {
            throw MigrationError.writeFailed("Copilot CLI did not return a valid imported session ID.")
        }
        return uuid.uuidString.lowercased()
    }

    private func stage(_ semanticJSONL: String) throws -> URL {
        let temporaryRoot = URL(filePath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
        let directory = temporaryRoot.appendingPathComponent(
            "ctxmv-copilot-import-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw MigrationError.writeFailed("Could not create a private temporary directory for Copilot import.")
        }

        let transcriptURL = directory.appendingPathComponent("session.jsonl")
        guard FileManager.default.createFile(
            atPath: transcriptURL.path,
            contents: Data(semanticJSONL.utf8),
            attributes: [.posixPermissions: 0o600]
        ) else {
            try? FileManager.default.removeItem(at: directory)
            throw MigrationError.writeFailed("Could not stage the Copilot session transcript.")
        }
        return transcriptURL
    }

    package static func importArguments(
        transcriptURL: URL,
        workingDirectory: String,
        dryRun: Bool
    ) -> [String] {
        var arguments = [
            "--no-auto-update",
            "--no-remote",
            "--no-remote-export",
            "sessions",
            "import",
        ]
        if dryRun { arguments.append("--dry-run") }
        arguments += [
            "--output", "json",
            "--working-directory", workingDirectory,
            "--name", importedSessionName,
            transcriptURL.path,
        ]
        return arguments
    }

    package static func processEnvironment(
        copilotHome: URL,
        path: String,
        temporaryDirectory: String
    ) -> [String: String] {
        [
            "PATH": path,
            "HOME": copilotHome.deletingLastPathComponent().path,
            "TMPDIR": temporaryDirectory,
            "COPILOT_HOME": copilotHome.path,
            "COPILOT_OFFLINE": "true",
        ]
    }

    private func run(_ arguments: [String], copilotHome: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = [Self.commandName] + arguments
        process.environment = Self.processEnvironment(
            copilotHome: copilotHome,
            path: ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
            temporaryDirectory: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
        )

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw MigrationError.writeFailed("\(Self.minimumCLIMessage) Copilot CLI could not be started.")
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw MigrationError.writeFailed("Copilot CLI session import failed. \(Self.minimumCLIMessage)")
        }
        return data
    }
}
