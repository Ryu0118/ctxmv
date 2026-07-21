import Foundation

struct KimiSessionDocument {
    let stateJSON: String
    let wireJSONL: String
}

private enum WireType: String {
    case metadata
    case turnPrompt = "turn.prompt"
    case appendMessage = "context.append_message"
    case appendLoopEvent = "context.append_loop_event"
}

private enum LoopType: String {
    case stepBegin = "step.begin"
    case contentPart = "content.part"
}

private enum PartType: String { case text }

private enum WireFormat {
    static let protocolVersion = "1.4"
    static let mainAgent = "main"
}

/// Builds kimi-code `state.json` + `agents/main/wire.jsonl` from a unified conversation.
/// Pure transformation — no I/O — so it can be unit-tested without a file system.
struct KimiCodeWireBuilder {
    /// `agents/main`, single-sourced: the migrator creates this dir, this builder writes it into `state.json`.
    static let mainAgentPath = "agents/" + WireFormat.mainAgent

    private enum Constants {
        static let titleMaxLength = 80
        static let defaultTitle = "Migrated session"
    }

    private enum OriginKind: String { case user, injection }

    func makeDocument(
        conversation: UnifiedConversation,
        sessionId: String,
        sessionDirPath: String,
        workDir: String
    ) -> KimiSessionDocument {
        let createdMs = MigratorUtils.epochMillis(from: conversation.createdAt)
        let origin = MigrationOrigin(
            originId: conversation.id,
            originSource: conversation.source,
            originMessageCount: conversation.messages.count,
            originDigest: MigrationDeduplicator.originDigest(for: conversation)
        )
        let meta = MigrationDeduplicator.makeMeta(origin: origin)

        let wireJSONL = buildWire(conversation: conversation, createdMs: createdMs)
        let stateJSON = buildState(
            conversation: conversation,
            sessionDirPath: sessionDirPath,
            workDir: workDir,
            meta: meta
        )
        return KimiSessionDocument(stateJSON: stateJSON, wireJSONL: wireJSONL)
    }

    private func buildWire(conversation: UnifiedConversation, createdMs: Int) -> String {
        var lines: [String] = []
        lines.appendIfEncodable(MetadataEvent(createdAt: createdMs))

        var turnCounter = -1
        // Native kimi increments `step` within a turn; reset on each new user turn.
        var stepCounter = 0
        for message in conversation.messages {
            let epochMs = MigratorUtils.epochMillis(from: message.timestamp ?? conversation.createdAt)
            let body = message.decodedContent(for: conversation.source)
            switch message.role {
            case .user where MessageFilter.isNoise(body):
                // kimi's TUI hides `injection` origins but keeps them in model context;
                // written as a user turn, injected noise renders as a visible user prompt.
                lines.appendIfEncodable(makeAppendMessage(body: body, originKind: .injection, epochMs: epochMs))
            case .user:
                turnCounter += 1
                stepCounter = 0
                lines.appendIfEncodable(TurnPromptEvent(
                    input: [TextPart(text: body)],
                    origin: Origin(kind: OriginKind.user.rawValue),
                    time: epochMs
                ))
                lines.appendIfEncodable(makeAppendMessage(body: body, originKind: .user, epochMs: epochMs))
            case .assistant:
                stepCounter += 1
                lines.append(contentsOf: makeAssistantEvents(
                    body: body,
                    turnId: String(max(turnCounter, 0)),
                    step: stepCounter,
                    epochMs: epochMs
                ))
            case .system, .tool:
                continue
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func makeAppendMessage(body: String, originKind: OriginKind, epochMs: Int) -> AppendMessageEvent {
        AppendMessageEvent(
            message: AppendedMessage(
                role: MessageRole.user.rawValue,
                content: [TextPart(text: body)],
                toolCalls: [],
                origin: Origin(kind: originKind.rawValue)
            ),
            time: epochMs
        )
    }

    /// One assistant reply = `step.begin` + `content.part` sharing a `stepUuid`, per native wires.
    /// Consecutive assistant messages share a turn; kimi's reader merges them on re-read
    /// (kimi→kimi re-migration changes the digest).
    private func makeAssistantEvents(body: String, turnId: String, step: Int, epochMs: Int) -> [String] {
        let stepUuid = UUID().uuidString.lowercased()
        return [
            LoopEvent(
                event: .stepBegin(StepBegin(uuid: stepUuid, turnId: turnId, step: step)),
                time: epochMs
            ),
            LoopEvent(
                event: .contentPart(ContentPart(
                    uuid: UUID().uuidString.lowercased(),
                    turnId: turnId,
                    step: step,
                    stepUuid: stepUuid,
                    part: Part(text: body)
                )),
                time: epochMs
            ),
        ].compactMap(MigratorUtils.encodeLine)
    }

    private func buildState(
        conversation: UnifiedConversation,
        sessionDirPath: String,
        workDir: String,
        meta: MigrationMeta
    ) -> String {
        let created = MigratorUtils.isoFormatter.string(from: conversation.createdAt)
        // Empty bodies and injected noise (same classification as the wire) must not become the title.
        let prompts = conversation.messages
            .filter { $0.role == .user }
            .map { $0.decodedContent(for: conversation.source) }
            .filter { !$0.isEmpty && !MessageFilter.isNoise($0) }
        let homedir = sessionDirPath + "/" + Self.mainAgentPath

        // Deliberately kimi-code's v1 state.json shape (ISO createdAt/updatedAt, `workDir` key, no
        // `id`/`version`/`archived`). Current kimi (`sessionMetaSchema`) uses epoch-ms + `cwd` instead,
        // but `FileSessionIndex`'s reader treats an absent `version` field as v1 and normalizes both
        // representations to epoch-ms on read — so v1 round-trips through current kimi without loss.
        // Writing v1 also keeps this in sync with AgentSessions' KimiCodeSessionReader, which parses
        // `createdAt` as a `String?` and reads `workDir`, not `cwd`.
        let state = StateFile(
            createdAt: created,
            updatedAt: created,
            title: (prompts.first?.truncated(to: Constants.titleMaxLength)) ?? Constants.defaultTitle,
            isCustomTitle: false,
            lastPrompt: prompts.last ?? "",
            agents: [WireFormat.mainAgent: AgentEntry(homedir: homedir)],
            custom: KimiCodeCustomMeta(ctxmvMigration: meta),
            workDir: workDir
        )
        return MigratorUtils.encodeLine(state) ?? "{}"
    }
}

private extension [String] {
    mutating func appendIfEncodable(_ value: some Encodable) {
        if let line = MigratorUtils.encodeLine(value) { append(line) }
    }
}

private struct MetadataEvent: Encodable {
    let type: String = WireType.metadata.rawValue
    let protocolVersion: String = WireFormat.protocolVersion
    let createdAt: Int

    enum CodingKeys: String, CodingKey {
        case type
        case protocolVersion = "protocol_version"
        case createdAt = "created_at"
    }
}

private struct TextPart: Encodable {
    let type: String = PartType.text.rawValue
    let text: String
}

private struct Origin: Encodable {
    let kind: String
}

private struct TurnPromptEvent: Encodable {
    let type: String = WireType.turnPrompt.rawValue
    let input: [TextPart]
    let origin: Origin
    let time: Int
}

private struct AppendedMessage: Encodable {
    let role: String
    let content: [TextPart]
    let toolCalls: [String]
    let origin: Origin
}

private struct AppendMessageEvent: Encodable {
    let type: String = WireType.appendMessage.rawValue
    let message: AppendedMessage
    let time: Int
}

private struct StepBegin: Encodable {
    let type: String = LoopType.stepBegin.rawValue
    let uuid: String
    let turnId: String
    let step: Int
}

private struct Part: Encodable {
    let type: String = PartType.text.rawValue
    let text: String
}

private struct ContentPart: Encodable {
    let type: String = LoopType.contentPart.rawValue
    let uuid: String
    let turnId: String
    let step: Int
    let stepUuid: String
    let part: Part
}

/// Wraps a `step.begin` or `content.part` under the `event` key; both payload cases are `Encodable`,
/// so the case's associated value is boxed as `any Encodable` rather than switched over to encode it.
private struct LoopEvent: Encodable {
    enum Payload {
        case stepBegin(StepBegin)
        case contentPart(ContentPart)

        var boxed: any Encodable {
            switch self {
            case let .stepBegin(value): value
            case let .contentPart(value): value
            }
        }
    }

    let type: String = WireType.appendLoopEvent.rawValue
    let event: Payload
    let time: Int

    enum CodingKeys: String, CodingKey { case type, event, time }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(time, forKey: .time)
        try container.encode(event.boxed, forKey: .event)
    }
}

private struct AgentEntry: Encodable {
    let homedir: String
    let type: String = WireFormat.mainAgent
    let parentAgentId: String? = nil

    enum CodingKeys: String, CodingKey { case homedir, type, parentAgentId }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(homedir, forKey: .homedir)
        try container.encode(type, forKey: .type)
        // Native kimi writes an explicit null here; synthesized encoding would omit the key.
        try container.encode(parentAgentId, forKey: .parentAgentId)
    }
}

/// The `custom` field of `state.json`. `Codable` so `KimiCodeMigrator`'s dedup scan can decode
/// the same shape this file encodes, instead of re-declaring it.
struct KimiCodeCustomMeta: Codable {
    let ctxmvMigration: MigrationMeta?

    enum CodingKeys: String, CodingKey {
        case ctxmvMigration = "ctxmv_migration"
    }
}

private struct StateFile: Encodable {
    let createdAt: String
    let updatedAt: String
    let title: String
    let isCustomTitle: Bool
    let lastPrompt: String
    let agents: [String: AgentEntry]
    let custom: KimiCodeCustomMeta
    let workDir: String
}
