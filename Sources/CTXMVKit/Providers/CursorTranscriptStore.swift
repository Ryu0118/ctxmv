import Foundation

/// Cursor transcript-backed session access, isolated from store.db handling.
struct CursorTranscriptStore: Sendable {
    private let fileSystem: FileSystemProtocol
    private let projectsDir: URL
    private let fileReader: JSONLFileReader
    private let projectPathResolver: CursorTranscriptProjectPathResolver

    init(fileSystem: FileSystemProtocol, projectsDir: URL) {
        self.fileSystem = fileSystem
        self.projectsDir = projectsDir
        fileReader = JSONLFileReader(fileSystem: fileSystem)
        projectPathResolver = CursorTranscriptProjectPathResolver(fileSystem: fileSystem)
    }

    func listSummaries() async throws -> [SessionSummary] {
        guard fileSystem.fileExists(atPath: projectsDir.path) else {
            return []
        }

        let transcriptFiles = try findAgentTranscriptFiles(in: projectsDir)
        return await withTaskGroup(of: SessionSummary?.self, returning: [SessionSummary].self) { group in
            for file in transcriptFiles {
                group.addTask {
                    try? self.summary(forTranscriptFile: file)
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

    func loadSession(id: String, projectPath: String? = nil, limit: Int?) throws -> UnifiedConversation? {
        guard let file = try transcriptFile(forSessionId: id) else {
            return nil
        }
        return try conversation(
            fromTranscriptFile: file,
            sessionId: id,
            projectPath: projectPath,
            limit: limit
        )
    }

    func projectPath(forSessionId sessionId: String) -> String? {
        guard let file = try? transcriptFile(forSessionId: sessionId) else {
            return nil
        }
        return resolvedProjectPath(forTranscriptFile: file)
    }

    func resolvedProjectPath(forTranscriptFile file: URL) -> String? {
        projectPathResolver.resolveProjectPath(for: file)
    }

    /// Builds summaries from recent transcript lines so listing stays cheap even for large transcripts.
    private func summary(forTranscriptFile file: URL) throws -> SessionSummary {
        let recentEntries = try fileReader.readRecentEntries(
            from: file,
            as: CursorAgentTranscriptEntry.self,
            initialMaxBytes: 131_072,
            limit: 20
        )
        let recentMessages = recentEntries.compactMap(message(fromTranscriptEntry:))
        let lastUserMessage = recentMessages
            .last(where: { $0.role == .user })?
            .decodedContent(for: .cursor)
            .truncated(to: 200)

        return try SessionSummary(
            id: file.deletingPathExtension().lastPathComponent,
            source: .cursor,
            projectPath: resolvedProjectPath(forTranscriptFile: file),
            createdAt: transcriptCreatedAt(file: file) ?? Date.distantPast,
            lastMessageAt: FileSystemProvider.fileModificationDate(file, fileSystem: fileSystem),
            model: nil,
            messageCount: 0,
            lastUserMessage: lastUserMessage,
            byteSize: FileSystemProvider.fileSize(file, fileSystem: fileSystem)
        )
    }

    private func conversation(
        fromTranscriptFile file: URL,
        sessionId: String,
        projectPath: String?,
        limit: Int?
    ) throws -> UnifiedConversation {
        let messages = try parseTranscriptEntries(file: file, limit: limit)
        let createdAt = try transcriptCreatedAt(file: file) ?? messages.first?.timestamp ?? Date.distantPast

        return UnifiedConversation(
            id: sessionId,
            source: .cursor,
            projectPath: projectPath ?? resolvedProjectPath(forTranscriptFile: file),
            createdAt: createdAt,
            model: nil,
            messages: messages
        )
    }

    private func parseTranscriptEntries(file: URL, limit: Int?) throws -> [UnifiedMessage] {
        let entries: [CursorAgentTranscriptEntry]
        if let limit, limit > 0 {
            entries = try fileReader.readRecentEntries(
                from: file,
                as: CursorAgentTranscriptEntry.self,
                initialMaxBytes: 131_072,
                limit: limit
            )
        } else {
            entries = try fileReader.readAllEntries(from: file, as: CursorAgentTranscriptEntry.self)
        }

        let messages = entries.compactMap(message(fromTranscriptEntry:))
        guard let limit, limit > 0 else {
            return messages
        }
        // Recent tail reads can still decode slightly more than requested, so trim after mapping.
        return Array(messages.suffix(limit))
    }

    private func transcriptCreatedAt(file: URL) throws -> Date? {
        try fileReader.readHeadEntries(
            from: file,
            as: CursorAgentTranscriptEntry.self,
            maxBytes: 16384
        )
        .compactMap { message(fromTranscriptEntry: $0)?.timestamp }
        .first
    }

    private func message(fromTranscriptEntry entry: CursorAgentTranscriptEntry) -> UnifiedMessage? {
        let rawRole = entry.role ?? entry.message?.role
        guard let rawRole,
              let role = MessageRole(rawValue: rawRole),
              role == .user || role == .assistant
        else {
            return nil
        }

        let content = CursorAgentContentDecoder.decode(entry.message?.content?.textContent ?? "")
        guard !content.isEmpty else {
            return nil
        }

        return UnifiedMessage(
            role: role,
            content: content,
            timestamp: entry.timestamp.flatMap(DateUtils.parseISO8601)
        )
    }

    private func transcriptFile(forSessionId sessionId: String) throws -> URL? {
        guard fileSystem.fileExists(atPath: projectsDir.path) else {
            return nil
        }

        return try findAgentTranscriptFiles(in: projectsDir)
            .first(where: { $0.deletingPathExtension().lastPathComponent == sessionId })
    }

    /// Recursively finds every `agent-transcripts` directory and returns the JSONL files beneath it.
    private func findAgentTranscriptFiles(in directory: URL) throws -> [URL] {
        guard fileSystem.fileExists(atPath: directory.path) else {
            return []
        }

        let entries = try fileSystem.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        var results: [URL] = []
        for entry in entries {
            if !isDirectory(entry) {
                continue
            }

            if entry.lastPathComponent == "agent-transcripts" {
                try results.append(contentsOf: findJSONLFilesRecursively(in: entry))
                continue
            }

            try results.append(contentsOf: findAgentTranscriptFiles(in: entry))
        }

        return results
    }

    private func findJSONLFilesRecursively(in directory: URL) throws -> [URL] {
        let entries = try fileSystem.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        var results: [URL] = []
        for entry in entries {
            if isDirectory(entry) {
                try results.append(contentsOf: findJSONLFilesRecursively(in: entry))
            } else if entry.pathExtension == "jsonl" {
                results.append(entry)
            }
        }

        return results
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        guard fileSystem.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue
    }
}
