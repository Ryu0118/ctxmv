import Foundation

/// Builds the semantic JSONL format accepted by `copilot sessions import`.
struct CopilotSemanticSessionBuilder: Sendable {
    func jsonl(for conversation: UnifiedConversation) -> String? {
        let header = CopilotSemanticSessionHeader(
            externalId: "ctxmv-\(UUID().uuidString.lowercased())",
            createdAt: MigratorUtils.isoFormatter.string(from: conversation.createdAt),
            source: CopilotSemanticSource(application: .ctxmv)
        )

        guard let headerLine = MigratorUtils.encodeLine(header) else { return nil }
        var lines = [headerLine]

        for message in conversation.messages where message.role == .user || message.role == .assistant {
            let record = CopilotSemanticMessage(
                id: UUID().uuidString.lowercased(),
                timestamp: MigratorUtils.isoFormatter.string(from: message.timestamp ?? conversation.createdAt),
                role: message.role,
                content: [CopilotSemanticTextPart(text: message.decodedContent(for: conversation.source))]
            )
            guard let line = MigratorUtils.encodeLine(record) else { return nil }
            lines.append(line)
        }

        return lines.joined(separator: "\n") + "\n"
    }
}

private enum CopilotSemanticRecordType: String, Encodable {
    case session
    case message
}

private enum CopilotSemanticPartType: String, Encodable {
    case text
}

private enum CopilotSemanticApplication: String, Encodable {
    case ctxmv
}

private struct CopilotSemanticSource: Encodable {
    let application: CopilotSemanticApplication
}

private struct CopilotSemanticSessionHeader: Encodable {
    let type = CopilotSemanticRecordType.session
    let version = 1
    let externalId: String
    let createdAt: String
    let source: CopilotSemanticSource
}

private struct CopilotSemanticMessage: Encodable {
    let type = CopilotSemanticRecordType.message
    let id: String
    let timestamp: String
    let role: MessageRole
    let content: [CopilotSemanticTextPart]
}

private struct CopilotSemanticTextPart: Encodable {
    let type = CopilotSemanticPartType.text
    let text: String
}
