import Foundation

/// Metadata inferred from a partial Claude Code session scan.
private struct SessionMetadata {
    var createdAt: Date?
    var model: String?
    var resolvedProjectPath: String?
    var hasSidechain: Bool

    var isObserver: Bool {
        hasSidechain || (resolvedProjectPath?.contains("observer-sessions") == true)
    }
}

/// Reads Claude Code JSONL sessions from the local session store.
struct ClaudeCodeProvider: SessionProvider, Sendable {
    private struct SessionFile: Sendable {
        let file: URL
        let projectPath: String?
    }

    let source: AgentSource = .claudeCode
    private let fileSystem: FileSystemProtocol
    private let baseDir: URL
    private let fileReader: JSONLFileReader

    init(
        fileSystem: FileSystemProtocol = DefaultFileSystem(),
        baseDir: URL? = nil
    ) {
        self.fileSystem = fileSystem
        self.baseDir = baseDir ?? fileSystem.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        fileReader = JSONLFileReader(fileSystem: fileSystem)
    }

    func listSessions() async throws -> [SessionSummary] {
        guard fileSystem.fileExists(atPath: baseDir.path) else {
            logger.debug("Base directory not found", metadata: ["path": "\(baseDir.path)"])
            return []
        }
        let projectDirs = try fileSystem.contentsOfDirectory(
            at: baseDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        logger.debug("Scanning \(projectDirs.count) project directories")

        let sessionFiles = try sessionFiles(in: projectDirs)
        let summaries = await SessionSummaryCollector.collect(sessionFiles) { sessionFile in
            try summary(for: sessionFile.file, projectPath: sessionFile.projectPath)
        }

        logger.info("📋 Discovered \(summaries.count) Claude Code sessions")
        return summaries
    }

    func loadSession(id: String, storagePath _: String?, limit: Int?) async throws -> UnifiedConversation? {
        guard fileSystem.fileExists(atPath: baseDir.path) else { return nil }
        let projectDirs = try fileSystem.contentsOfDirectory(
            at: baseDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )

        for sessionFile in try sessionFiles(in: projectDirs) where sessionFile.file.deletingPathExtension().lastPathComponent == id {
            logger.debug("Loading session", metadata: ["id": "\(id)", "file": "\(sessionFile.file.lastPathComponent)"])
            return try conversation(
                from: sessionFile.file,
                sessionId: id,
                projectPath: sessionFile.projectPath,
                limit: limit
            )
        }
        return nil
    }

    func jsonlFiles(in directory: URL) throws -> [URL] {
        guard fileSystem.fileExists(atPath: directory.path) else { return [] }
        return try fileSystem.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "jsonl" }
    }

    private func sessionFiles(in projectDirs: [URL]) throws -> [SessionFile] {
        try projectDirs.flatMap { projectDir in
            let projectPath = decodeProjectPath(projectDir.lastPathComponent)
            return try jsonlFiles(in: projectDir).map {
                SessionFile(file: $0, projectPath: projectPath)
            }
        }
    }

    /// Scans partial entry slices to recover metadata without decoding the whole session file.
    private func scanMetadata(entries: some Sequence<ClaudeCodeEntry>, projectPath: String?) -> SessionMetadata {
        var meta = SessionMetadata(
            createdAt: nil, model: nil, resolvedProjectPath: projectPath, hasSidechain: false
        )
        for entry in entries {
            if let cwd = entry.cwd, !cwd.isEmpty {
                meta.resolvedProjectPath = cwd
            }
            if entry.isSidechain == true {
                meta.hasSidechain = true
            }
            if meta.createdAt == nil, let timestamp = entry.timestamp {
                meta.createdAt = parseISO8601(timestamp)
            }
            if meta.model == nil, let model = entry.model {
                meta.model = model
            }
        }
        return meta
    }

    /// Builds a summary using head reads for metadata and tail reads for the latest user prompt.
    func summary(for file: URL, projectPath: String?) throws -> SessionSummary {
        let sessionId = file.deletingPathExtension().lastPathComponent
        let headEntries = try readMetadataEntries(file: file)
        let meta = scanMetadata(entries: headEntries, projectPath: projectPath)

        // Read only the tail to avoid loading very large observer sessions just for the preview line.
        let userMessages: [String] = try fileReader.readRecentValues(
            from: file,
            as: ClaudeCodeEntry.self,
            initialMaxBytes: 262_144,
            limit: 20
        ) { entry in
            guard extractRole(from: entry) == .user else {
                return nil
            }
            let content = extractContent(from: entry)
            return content.isEmpty ? nil : content
        }
        let lastUserMessage = MessageFilter.lastMeaningful(userMessages)

        let lastMessageAt = FileSystemProvider.fileModificationDate(file, fileSystem: fileSystem)

        return SessionSummary(
            id: sessionId,
            source: .claudeCode,
            projectPath: meta.resolvedProjectPath,
            createdAt: meta.createdAt ?? Date.distantPast,
            lastMessageAt: lastMessageAt,
            model: meta.model,
            messageCount: 0,
            lastUserMessage: lastUserMessage,
            byteSize: FileSystemProvider.fileSize(file, fileSystem: fileSystem),
            isObserverSession: meta.isObserver
        )
    }

    func conversation(from file: URL, sessionId: String, projectPath: String?, limit: Int?) throws -> UnifiedConversation {
        let meta = try readConversationMetadata(file: file, projectPath: projectPath)
        let messages = try readConversationMessages(file: file, limit: limit)

        return UnifiedConversation(
            id: sessionId,
            source: .claudeCode,
            projectPath: meta.resolvedProjectPath,
            createdAt: meta.createdAt ?? Date.distantPast,
            model: meta.model,
            messages: messages,
            isObserverSession: meta.isObserver
        )
    }

    private func readConversationMetadata(file: URL, projectPath: String?) throws -> SessionMetadata {
        try scanMetadata(entries: readMetadataEntries(file: file), projectPath: projectPath)
    }

    private func readConversationMessages(file: URL, limit: Int?) throws -> [UnifiedMessage] {
        if let limit, limit > 0 {
            return try fileReader.readRecentValues(
                from: file,
                as: ClaudeCodeEntry.self,
                initialMaxBytes: 262_144,
                limit: limit,
                transform: mapMessage(from:)
            )
        }

        return try parseMessages(fileReader.readAllEntries(from: file, as: ClaudeCodeEntry.self))
    }

    private func readMetadataEntries(file: URL) throws -> [ClaudeCodeEntry] {
        try fileReader.readHeadEntries(
            from: file,
            as: ClaudeCodeEntry.self,
            maxBytes: 32768,
            maxLines: 50
        )
        .filter { !shouldSkipEntry($0) }
    }

    private func parseMessages(_ entries: [ClaudeCodeEntry]) -> [UnifiedMessage] {
        entries.compactMap(mapMessage(from:))
    }

    private func mapMessage(from entry: ClaudeCodeEntry) -> UnifiedMessage? {
        guard !shouldSkipEntry(entry),
              let role = extractRole(from: entry),
              role == .user || role == .assistant
        else {
            return nil
        }

        let content = extractContent(from: entry)
        guard !content.isEmpty else {
            return nil
        }

        return UnifiedMessage(
            role: role,
            content: content,
            timestamp: entry.timestamp.flatMap(parseISO8601)
        )
    }

    func decodeLine(_ line: String) -> ClaudeCodeEntry? {
        JSONLParser.decodeLine(line, as: ClaudeCodeEntry.self)
    }

    func shouldSkipEntry(_ entry: ClaudeCodeEntry) -> Bool {
        // Progress and file-history snapshots are implementation noise, not user-visible conversation turns.
        entry.entryType == .progress || entry.entryType == .fileHistorySnapshot
    }

    func extractRole(from entry: ClaudeCodeEntry) -> MessageRole? {
        if entry.entryType == .user {
            return .user
        }
        if entry.message?.messageRole == .assistant {
            return .assistant
        }
        return nil
    }

    func extractContent(from entry: ClaudeCodeEntry) -> String {
        entry.message?.content?.textContent ?? ""
    }

    /// Decode encoded-cwd: "-Users-example-workspace-foo" → "/Users/example/workspace/foo"
    static func decodeProjectPath(_ encoded: String) -> String? {
        guard encoded.hasPrefix("-") else { return nil }
        return "/" + encoded.dropFirst().replacingOccurrences(of: "-", with: "/")
    }

    private func decodeProjectPath(_ encoded: String) -> String? {
        Self.decodeProjectPath(encoded)
    }

    private func parseISO8601(_ string: String) -> Date? {
        DateUtils.parseISO8601(string)
    }
}
