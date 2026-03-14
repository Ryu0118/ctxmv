import Foundation

/// Resolves Cursor project paths from transcript contents and workspace names.
struct CursorTranscriptProjectPathResolver: Sendable {
    private let fileSystem: FileSystemProtocol

    init(fileSystem: FileSystemProtocol) {
        self.fileSystem = fileSystem
    }

    /// Scans transcript head/tail chunks for tool payloads that reveal the working directory.
    func resolveProjectPath(for transcriptFile: URL) -> String? {
        let workspacePath = decodeProjectPath(fromTranscriptFile: transcriptFile)

        if let headData = try? FileSystemProvider.readHead(fileSystem: fileSystem, file: transcriptFile, maxBytes: 131_072),
           let path = projectPath(inTranscriptData: headData, workspacePath: workspacePath)
        {
            return path
        }

        if let tailData = try? FileSystemProvider.readTail(fileSystem: fileSystem, file: transcriptFile, maxBytes: 262_144),
           let path = projectPath(inTranscriptData: tailData, workspacePath: workspacePath)
        {
            return path
        }

        return workspacePath
    }

    /// Parses newline-delimited JSON objects and returns the first project path hint found.
    private func projectPath(inTranscriptData data: Data, workspacePath: String?) -> String? {
        String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .lazy
            .compactMap(jsonObject(from:))
            .compactMap { projectPath(in: $0, workspacePath: workspacePath) }
            .first
    }

    /// Walks arbitrary transcript JSON recursively because tool payloads are nested under heterogeneous keys.
    private func projectPath(in value: Any, workspacePath: String?) -> String? {
        switch value {
        case let dictionary as [String: Any]:
            return projectPath(in: dictionary, workspacePath: workspacePath)
                ?? dictionary.values.lazy.compactMap { projectPath(in: $0, workspacePath: workspacePath) }.first

        case let array as [Any]:
            return array.lazy.compactMap { projectPath(in: $0, workspacePath: workspacePath) }.first

        default:
            return nil
        }
    }

    private func projectPath(in dictionary: [String: Any], workspacePath: String?) -> String? {
        if let workingDirectory = dictionary["working_directory"] as? String {
            return normalizedProjectDirectory(at: workingDirectory)
        }

        if let path = dictionary["path"] as? String,
           let workspacePath,
           path.hasPrefix(workspacePath)
        {
            return workspacePath
        }

        return nil
    }

    private func jsonObject(from line: Substring) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(line.utf8))
    }

    private func normalizedProjectDirectory(at path: String) -> String? {
        let url = URL(filePath: path).standardizedFileURL
        var isDirectory = ObjCBool(false)
        guard fileSystem.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return url.path
    }

    private func decodeProjectPath(fromTranscriptFile file: URL) -> String? {
        let agentTranscriptsDirectory = sequence(
            first: file.deletingLastPathComponent(),
            next: parentDirectory(of:)
        )
        .first(where: { $0.lastPathComponent == "agent-transcripts" })

        guard let encodedWorkspace = agentTranscriptsDirectory?
            .deletingLastPathComponent()
            .lastPathComponent,
            !encodedWorkspace.isEmpty
        else {
            return nil
        }

        return "/" + encodedWorkspace.replacingOccurrences(of: "-", with: "/")
    }

    private func parentDirectory(of url: URL) -> URL? {
        let parent = url.deletingLastPathComponent()
        return parent.path == url.path ? nil : parent
    }
}
