import Foundation
#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif

/// Stores the blobs required to populate a Cursor conversation store.
struct CursorConversationBlobs: Sendable {
    let messageBlobs: [(idHex: String, data: Data)]
    let rootBlobID: String
}

/// Builds Cursor blob payloads from a unified conversation.
struct CursorConversationBlobBuilder: Sendable {
    func blobs(for conversation: UnifiedConversation, projectPath: String) -> CursorConversationBlobs {
        let messages = conversation.messages.filter { $0.role == .user || $0.role == .assistant }
        var blobsByID: [String: Data] = [:]

        let rootPromptHashes = buildRootPromptHashes(
            from: messages,
            source: conversation.source,
            blobsByID: &blobsByID
        )
        let turnHashes = buildTurnHashes(
            from: messages,
            source: conversation.source,
            blobsByID: &blobsByID
        )

        let rootData = buildConversationStateRoot(
            rootPromptMessageHashes: rootPromptHashes,
            turnHashes: turnHashes,
            workspaceURI: fileURI(for: projectPath),
            modeValue: 0
        )
        let rootHash = sha256Data(rootData)
        let rootBlobID = MigratorUtils.hexString(rootHash)
        blobsByID[rootBlobID] = rootData

        return CursorConversationBlobs(
            messageBlobs: blobsByID
                .map { (idHex: $0.key, data: $0.value) }
                .sorted { $0.idHex < $1.idHex },
            rootBlobID: rootBlobID
        )
    }

    private func buildRootPromptHashes(
        from messages: [UnifiedMessage],
        source: AgentSource,
        blobsByID: inout [String: Data]
    ) -> [Data] {
        messages.compactMap { message in
            let content = message.decodedContent(for: source)
            let blob = CursorRoleBlob(
                role: message.role.rawValue,
                content: [CursorRoleTextBlock(type: ContentBlockType.text.rawValue, text: content)]
            )
            guard let blobData = try? MigratorUtils.jsonEncoder.encode(blob) else {
                return nil
            }

            let hash = sha256Data(blobData)
            blobsByID[MigratorUtils.hexString(hash)] = blobData
            return hash
        }
    }

    private func buildTurnHashes(
        from messages: [UnifiedMessage],
        source: AgentSource,
        blobsByID: inout [String: Data]
    ) -> [Data] {
        var turnHashes: [Data] = []
        var pendingUserMessage: UnifiedMessage?
        var pendingAssistantSteps: [String] = []

        func storeBlob(_ data: Data) -> Data {
            let hash = sha256Data(data)
            blobsByID[MigratorUtils.hexString(hash)] = data
            return hash
        }

        func flushTurn() {
            guard let userMessage = pendingUserMessage else {
                return
            }

            let userBlob = buildUserMessageBlob(
                text: userMessage.decodedContent(for: source),
                messageID: UUID().uuidString.lowercased()
            )
            let userHash = storeBlob(userBlob)

            let stepHashes = pendingAssistantSteps.map { stepText in
                storeBlob(buildConversationStepAssistantBlob(text: stepText))
            }
            let agentTurnBlob = buildAgentConversationTurnStructureBlob(
                userMessageHash: userHash,
                stepHashes: stepHashes,
                requestID: UUID().uuidString.lowercased()
            )
            turnHashes.append(storeBlob(buildConversationTurnStructureBlob(agentTurnStructure: agentTurnBlob)))

            pendingUserMessage = nil
            pendingAssistantSteps.removeAll(keepingCapacity: false)
        }

        for message in messages {
            switch message.role {
            case .user:
                flushTurn()
                pendingUserMessage = message
            case .assistant:
                guard pendingUserMessage != nil else {
                    continue
                }
                pendingAssistantSteps.append(message.decodedContent(for: source))
            default:
                continue
            }
        }

        flushTurn()
        return turnHashes
    }

    private func buildConversationStateRoot(
        rootPromptMessageHashes: [Data],
        turnHashes: [Data],
        workspaceURI: String,
        modeValue: UInt64
    ) -> Data {
        var data = Data()
        for hash in rootPromptMessageHashes {
            appendLengthDelimitedField(number: 1, value: hash, to: &data)
        }
        for turnHash in turnHashes {
            appendLengthDelimitedField(number: 8, value: turnHash, to: &data)
        }
        appendLengthDelimitedField(number: 9, value: Data(workspaceURI.utf8), to: &data)
        appendVarintField(number: 10, value: modeValue, to: &data)
        return data
    }

    // agent.v1.UserMessage
    private func buildUserMessageBlob(text: String, messageID: String) -> Data {
        var data = Data()
        appendLengthDelimitedField(number: 1, value: Data(text.utf8), to: &data)
        appendLengthDelimitedField(number: 2, value: Data(messageID.utf8), to: &data)
        return data
    }

    // agent.v1.AssistantMessage
    private func buildAssistantMessageBlob(text: String) -> Data {
        var data = Data()
        appendLengthDelimitedField(number: 1, value: Data(text.utf8), to: &data)
        return data
    }

    // agent.v1.ConversationStep
    private func buildConversationStepAssistantBlob(text: String) -> Data {
        var data = Data()
        appendLengthDelimitedField(number: 1, value: buildAssistantMessageBlob(text: text), to: &data)
        return data
    }

    // agent.v1.AgentConversationTurnStructure
    private func buildAgentConversationTurnStructureBlob(
        userMessageHash: Data,
        stepHashes: [Data],
        requestID: String
    ) -> Data {
        var data = Data()
        appendLengthDelimitedField(number: 1, value: userMessageHash, to: &data)
        for stepHash in stepHashes {
            appendLengthDelimitedField(number: 2, value: stepHash, to: &data)
        }
        appendLengthDelimitedField(number: 3, value: Data(requestID.utf8), to: &data)
        return data
    }

    // agent.v1.ConversationTurnStructure
    private func buildConversationTurnStructureBlob(agentTurnStructure: Data) -> Data {
        var data = Data()
        appendLengthDelimitedField(number: 1, value: agentTurnStructure, to: &data)
        return data
    }

    private func appendVarintField(number: UInt64, value: UInt64, to data: inout Data) {
        appendVarint((number << 3) | 0, to: &data)
        appendVarint(value, to: &data)
    }

    private func appendLengthDelimitedField(number: UInt64, value: Data, to data: inout Data) {
        appendVarint((number << 3) | 2, to: &data)
        appendVarint(UInt64(value.count), to: &data)
        data.append(value)
    }

    private func appendVarint(_ value: UInt64, to data: inout Data) {
        var remaining = value
        while true {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 {
                byte |= 0x80
            }
            data.append(byte)
            if remaining == 0 {
                break
            }
        }
    }

    private func sha256Data(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    private func fileURI(for projectPath: String) -> String {
        projectPath.hasPrefix("file://") ? projectPath : "file://\(projectPath)"
    }
}

private struct CursorRoleBlob: Codable, Sendable {
    let role: String
    let content: [CursorRoleTextBlock]
}

private struct CursorRoleTextBlock: Codable, Sendable {
    let type: String
    let text: String
}
