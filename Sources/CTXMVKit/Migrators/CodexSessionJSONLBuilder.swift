import Foundation

/// Builds Codex session JSONL from a unified conversation model.
/// Pure transformation logic lives here so migration I/O stays easy to test.
struct CodexSessionJSONLBuilder: Sendable {
    private let workingDirectoryProvider: @Sendable () -> String

    init(
        workingDirectoryProvider: @escaping @Sendable () -> String = { FileManager.default.currentDirectoryPath }
    ) {
        self.workingDirectoryProvider = workingDirectoryProvider
    }

    /// Returns the complete JSONL document, including migration metadata.
    func jsonl(for conversation: UnifiedConversation, sessionId: String) -> String {
        makeDocument(conversation: conversation, sessionId: sessionId).jsonl
    }

    /// Produces the structured document first so tests can assert on entries
    /// without snapshotting raw JSON strings.
    func makeDocument(conversation: UnifiedConversation, sessionId: String) -> CodexSessionDocument {
        let context = BuildContext(
            conversation: conversation,
            sessionId: sessionId,
            fallbackWorkingDirectory: conversation.projectPath ?? workingDirectoryProvider()
        )

        return CodexSessionDocument(
            migrationMetadata: makeMigrationMetadata(context: context),
            entries: makeEntries(context: context)
        )
    }

    private func makeMigrationMetadata(context: BuildContext) -> MigrationMeta {
        MigrationDeduplicator.makeMeta(
            originId: context.conversation.id,
            originSource: context.conversation.source,
            originMessageCount: context.conversation.messages.count,
            originDigest: context.originDigest
        )
    }

    private func makeEntries(context: BuildContext) -> [CodexEntry] {
        var hasSeenUserMessage = false
        return [makeSessionMetaEntry(context: context)] + context.conversation.messages.flatMap { message in
            // Only the first user prompt is sanitized; later messages should preserve
            // the original command-output text because it may be the user's intent.
            let entries = makeEntries(
                for: message,
                in: context,
                hasSeenPriorUserMessage: hasSeenUserMessage
            )

            if message.role == .user {
                hasSeenUserMessage = true
            }

            return entries
        }
    }

    private func makeSessionMetaEntry(context: BuildContext) -> CodexEntry {
        CodexEntry(
            timestamp: context.createdTimestamp,
            type: CodexEntryType.sessionMeta.rawValue,
            payload: CodexPayload(
                id: context.sessionId,
                timestamp: context.createdTimestamp,
                cwd: context.workingDirectory,
                originator: MetaDefaults.originator,
                cli_version: MetaDefaults.cliVersion,
                source: MetaDefaults.source,
                model_provider: MetaDefaults.modelProvider
            )
        )
    }

    private func makeEntries(
        for message: UnifiedMessage,
        in context: BuildContext,
        hasSeenPriorUserMessage: Bool
    ) -> [CodexEntry] {
        let timestamp = context.timestamp(for: message)

        switch message.role {
        case .user:
            return [
                makeEventMessageEntry(
                    payloadType: .userMessage,
                    message: normalizedUserBody(
                        for: message,
                        source: context.conversation.source,
                        hasSeenPriorUserMessage: hasSeenPriorUserMessage
                    ),
                    timestamp: timestamp
                ),
            ]
        case .assistant:
            let body = message.decodedContent(for: context.conversation.source)
            return [
                // Codex resume expects the assistant answer in both formats.
                makeEventMessageEntry(
                    payloadType: .agentMessage,
                    message: body,
                    timestamp: timestamp,
                    phase: .finalAnswer
                ),
                makeResponseItemEntry(message: body, timestamp: timestamp),
            ]
        case .system, .tool:
            return []
        }
    }

    private func normalizedUserBody(
        for message: UnifiedMessage,
        source: AgentSource,
        hasSeenPriorUserMessage: Bool
    ) -> String {
        let decodedBody = message.decodedContent(for: source)
        guard !hasSeenPriorUserMessage, MessageFilter.isNoise(decodedBody) else {
            return decodedBody
        }
        return UserMessageDefaults.placeholderForNoise
    }

    private func makeEventMessageEntry(
        payloadType: CodexPayloadType,
        message: String,
        timestamp: String,
        phase: CodexPayloadPhase? = nil
    ) -> CodexEntry {
        CodexEntry(
            timestamp: timestamp,
            type: CodexEntryType.eventMsg.rawValue,
            payload: CodexPayload(
                type: payloadType.rawValue,
                message: message,
                phase: phase?.rawValue
            )
        )
    }

    private func makeResponseItemEntry(message: String, timestamp: String) -> CodexEntry {
        CodexEntry(
            timestamp: timestamp,
            type: CodexEntryType.responseItem.rawValue,
            payload: CodexPayload(
                type: CodexPayloadType.message.rawValue,
                role: CodexPayloadRole.assistant.rawValue,
                content: [ContentBlock(type: .outputText, text: message)],
                phase: CodexPayloadPhase.finalAnswer.rawValue
            )
        )
    }
}

/// Structured representation of a Codex session file before JSON encoding.
struct CodexSessionDocument: Sendable {
    let migrationMetadata: MigrationMeta
    let entries: [CodexEntry]

    /// Serializes the migration metadata line first, followed by the Codex entries.
    var jsonl: String {
        let lines = [migrationMetadata]
            .compactMap(MigratorUtils.encodeLine)
            + entries.compactMap(MigratorUtils.encodeLine)
        return lines.joined(separator: "\n") + "\n"
    }
}

private extension CodexSessionJSONLBuilder {
    /// Provides default metadata values for generated Codex sessions.
    enum MetaDefaults {
        static let originator = "ctxmv"
        static let source = "cli"
        static let modelProvider = "openai"
        static let cliVersion = "ctxmv"
    }

    /// Provides fallback user-message content for noisy first prompts.
    enum UserMessageDefaults {
        static let placeholderForNoise = "(Command output)"
    }

    /// Precomputed values shared across entry builders so formatting and
    /// digest calculation stay single-sourced.
    struct BuildContext: Sendable {
        let conversation: UnifiedConversation
        let sessionId: String
        let originDigest: String
        let createdTimestamp: String
        let workingDirectory: String

        init(
            conversation: UnifiedConversation,
            sessionId: String,
            fallbackWorkingDirectory: String
        ) {
            self.conversation = conversation
            self.sessionId = sessionId
            originDigest = MigrationDeduplicator.originDigest(for: conversation)
            createdTimestamp = MigratorUtils.isoFormatter.string(from: conversation.createdAt)
            workingDirectory = fallbackWorkingDirectory
        }

        func timestamp(for message: UnifiedMessage) -> String {
            MigratorUtils.isoFormatter.string(from: message.timestamp ?? conversation.createdAt)
        }
    }
}
