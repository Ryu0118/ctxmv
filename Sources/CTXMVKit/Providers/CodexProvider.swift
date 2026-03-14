import Foundation

/// Reads Codex rollout files from the local session store.
struct CodexProvider: SessionProvider, Sendable {
    let source: AgentSource = .codex
    private let fileSystem: FileSystemProtocol
    private let baseDir: URL
    private let fileReader: JSONLFileReader

    init(
        fileSystem: FileSystemProtocol = DefaultFileSystem(),
        baseDir: URL? = nil
    ) {
        self.fileSystem = fileSystem
        self.baseDir = baseDir ?? fileSystem.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")
        fileReader = JSONLFileReader(fileSystem: fileSystem)
    }

    func listSessions() async throws -> [SessionSummary] {
        guard fileSystem.fileExists(atPath: baseDir.path) else {
            logger.debug("Base directory not found", metadata: ["path": "\(baseDir.path)"])
            return []
        }
        let files = try findRolloutFiles(in: baseDir)
        logger.debug("Found \(files.count) rollout files")

        let summaries = await SessionSummaryCollector.collect(files) { file in
            try summary(for: file)
        }

        logger.info("📋 Discovered \(summaries.count) Codex sessions")
        return summaries
    }

    func loadSession(id: String, storagePath _: String?, limit: Int?) async throws -> UnifiedConversation? {
        guard fileSystem.fileExists(atPath: baseDir.path) else { return nil }
        let files = try findRolloutFiles(in: baseDir)
        guard let file = try files.first(where: { try fileMatchesSessionID($0, id: id) }) else {
            return nil
        }
        logger.debug("Loading session", metadata: ["id": "\(id)", "file": "\(file.lastPathComponent)"])
        return try conversation(from: file, limit: limit)
    }

    func findRolloutFiles(in dir: URL) throws -> [URL] {
        let entries = try fileSystem.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        let rollouts = entries.filter {
            $0.lastPathComponent.hasPrefix("rollout-") && $0.pathExtension == "jsonl"
        }
        let nested = entries
            .filter { $0.hasDirectoryPath || $0.pathExtension.isEmpty }
            .flatMap { (try? findRolloutFiles(in: $0)) ?? [] }
        return rollouts + nested
    }

    func extractSessionId(from file: URL) -> String? {
        guard let data = fileSystem.contents(atPath: file.path),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let firstLine = text.components(separatedBy: .newlines).first ?? ""
        guard let entry = decodeLine(firstLine) else { return nil }
        return entry.id ?? entry.payload?.id
    }

    private func fileMatchesSessionID(_ file: URL, id: String) throws -> Bool {
        // Fast path: Codex rollout file names usually end with the session UUID.
        if file.deletingPathExtension().lastPathComponent.hasSuffix(id) {
            return true
        }

        // Fallback: parse head entries because session_meta may not be on line 1.
        let metadata = try extractMetadata(from: metadataEntries(file: file))
        if metadata.sessionId == id {
            return true
        }

        // Legacy fallback for very old formats that may store id on the first line.
        return extractSessionId(from: file) == id
    }

    func summary(for file: URL) throws -> SessionSummary {
        // Codex lines can be very large (AGENTS.md context etc.), so use generous byte limits.
        // Head: metadata extraction (session_meta is typically in first few lines)
        let meta = try extractMetadata(from: metadataEntries(file: file))

        // Tail: last user message
        let userMessages: [String] = try fileReader.readRecentValues(
            from: file,
            as: CodexEntry.self,
            initialMaxBytes: 131_072,
            limit: 20
        ) { entry in
            guard extractRole(from: entry) == .user else {
                return nil
            }
            let content = extractContent(from: entry)
            return content.isEmpty ? nil : content
        }

        let lastUserMessage = MessageFilter.lastMeaningful(userMessages)
            ?? (userMessages.isEmpty ? nil : "(Command output)")

        let lastMessageAt = FileSystemProvider.fileModificationDate(file, fileSystem: fileSystem)

        return SessionSummary(
            id: meta.sessionId ?? file.deletingPathExtension().lastPathComponent,
            source: .codex,
            projectPath: meta.projectPath,
            createdAt: meta.createdAt ?? Date.distantPast,
            lastMessageAt: lastMessageAt,
            model: nil,
            messageCount: 0,
            lastUserMessage: lastUserMessage,
            byteSize: FileSystemProvider.fileSize(file, fileSystem: fileSystem)
        )
    }

    func conversation(from file: URL, limit: Int?) throws -> UnifiedConversation {
        let meta = try readConversationMetadata(file: file)
        let messages = try readConversationMessages(file: file, limit: limit)

        return UnifiedConversation(
            id: meta.sessionId ?? file.deletingPathExtension().lastPathComponent,
            source: .codex,
            projectPath: meta.projectPath,
            createdAt: meta.createdAt ?? Date.distantPast,
            model: nil,
            messages: messages
        )
    }

    private func readConversationMetadata(file: URL) throws -> EntryMetadata {
        try extractMetadata(from: metadataEntries(file: file))
    }

    private func readConversationMessages(file: URL, limit: Int?) throws -> [UnifiedMessage] {
        if let limit, limit > 0 {
            return try fileReader.readRecentValues(
                from: file,
                as: CodexEntry.self,
                initialMaxBytes: 262_144,
                limit: limit,
                transform: mapMessage(from:)
            )
        }

        return try parseMessages(fileReader.readAllEntries(from: file, as: CodexEntry.self))
    }

    private func metadataEntries(file: URL) throws -> [CodexEntry] {
        try fileReader.readHeadEntries(
            from: file,
            as: CodexEntry.self,
            maxBytes: 131_072,
            maxLines: 50
        )
    }

    private func parseMessages(_ entries: [CodexEntry]) -> [UnifiedMessage] {
        let allMessages = entries.compactMap(mapMessage(from:))

        // Deduplicate: event_msg agent_message and response_item both record assistant content
        var seen = Set<String>()
        let messages = allMessages.filter { msg in
            let key = "\(msg.role.rawValue):\(msg.content.prefix(500))"
            return seen.insert(key).inserted
        }
        return messages
    }

    private func mapMessage(from entry: CodexEntry) -> UnifiedMessage? {
        guard let role = extractRole(from: entry),
              role == .user || role == .assistant
        else {
            return nil
        }

        let content = extractContent(from: entry)
        guard !content.isEmpty else {
            return nil
        }

        let timestamp = (entry.timestamp ?? entry.payload?.timestamp)
            .flatMap(DateUtils.parseISO8601)
        return UnifiedMessage(role: role, content: content, timestamp: timestamp)
    }

    private struct EntryMetadata {
        var sessionId: String?
        var createdAt: Date?
        var projectPath: String?
    }

    private func extractMetadata(from entries: [CodexEntry]) -> EntryMetadata {
        var meta = EntryMetadata()
        for entry in entries {
            if meta.sessionId == nil, let sessionId = entry.id ?? entry.payload?.id {
                meta.sessionId = sessionId
            }
            if meta.createdAt == nil,
               let timestamp = entry.timestamp ?? entry.payload?.timestamp
            {
                meta.createdAt = DateUtils.parseISO8601(timestamp)
            }
            if meta.projectPath == nil, entry.entryType == .sessionMeta,
               let cwd = entry.payload?.cwd
            {
                meta.projectPath = cwd
            }
            if meta.sessionId != nil && meta.createdAt != nil && meta.projectPath != nil {
                break
            }
        }
        return meta
    }

    func decodeLine(_ line: String) -> CodexEntry? {
        JSONLParser.decodeLine(line, as: CodexEntry.self)
    }

    func extractRole(from entry: CodexEntry) -> MessageRole? {
        guard let entryType = entry.entryType else { return nil }

        if entryType == .eventMsg {
            if entry.payload?.payloadType == .userMessage {
                return .user
            }
            if entry.payload?.payloadType == .agentMessage {
                return .assistant
            }
        }

        if entryType == .responseItem {
            let explicitRole =
                entry.payload?.payloadRole
                    ?? entry.item?.role.flatMap(CodexPayloadRole.init(rawValue:))
                    ?? entry.items?.first?.role.flatMap(CodexPayloadRole.init(rawValue:))

            if explicitRole == .assistant {
                return .assistant
            }
            // Legacy fallback: older Codex formats may omit explicit role but keep text content.
            if explicitRole == nil, !extractContent(from: entry).isEmpty {
                return .assistant
            }
        }

        return nil
    }

    func extractContent(from entry: CodexEntry) -> String {
        guard let entryType = entry.entryType else { return "" }

        if entryType == .eventMsg {
            return extractEventMsgContent(from: entry)
        }

        if entryType == .responseItem {
            return extractResponseItemContent(from: entry)
        }

        return ""
    }

    private func extractEventMsgContent(from entry: CodexEntry) -> String {
        if entry.payload?.payloadType == .userMessage,
           let message = entry.payload?.message
        {
            return message
        }
        if entry.payload?.payloadType == .agentMessage,
           let message = entry.payload?.message
        {
            return message
        }
        return ""
    }

    private func extractResponseItemContent(from entry: CodexEntry) -> String {
        let payloadText = joinTextBlocks(entry.payload?.content)
        if !payloadText.isEmpty { return payloadText }

        let itemText = joinTextBlocks(entry.item?.content)
        if !itemText.isEmpty { return itemText }

        if let items = entry.items {
            let text = items.compactMap { item -> String? in
                guard let content = item.content else { return nil }
                let joined = joinTextBlocks(content)
                return joined.isEmpty ? nil : joined
            }.joined(separator: "\n")
            if !text.isEmpty { return text }
        }

        if let lastAgentMessage = entry.payload?.last_agent_message,
           !lastAgentMessage.isEmpty
        {
            return lastAgentMessage
        }

        return ""
    }

    private func joinTextBlocks(_ blocks: [ContentBlock]?) -> String {
        guard let blocks else { return "" }
        return blocks.compactMap { block -> String? in
            guard let blockType = block.blockType,
                  blockType == .text || blockType == .outputText || blockType == .inputText
            else {
                return nil
            }
            return block.text
        }.joined(separator: "\n")
    }
}
