@testable import CTXMVKit
import Foundation
import Testing

struct KimiCodeWireBuilderTests {
    private func decodeLines(_ jsonl: String) -> [[String: Any]] {
        jsonl.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
    }

    /// Shared arrange+act step for the `buildsWire*` tests below: one two-message
    /// conversation built into wire lines, each test then asserts a single event.
    private func makeWireLines() -> [[String: Any]] {
        let convo = TestFixtures.makeConversation(
            id: "kimi-build",
            source: .claudeCode,
            projectPath: "/mock/project",
            messages: [
                UnifiedMessage(role: .user, content: "Hi", timestamp: TestFixtures.sampleDate),
                UnifiedMessage(role: .assistant, content: "Hello!", timestamp: TestFixtures.sampleDate),
            ]
        )
        let doc = KimiCodeWireBuilder().makeDocument(
            conversation: convo,
            sessionId: "session_abc",
            sessionDirPath: "/home/.kimi-code/sessions/wd_project_deadbeef0000/session_abc",
            workDir: "/mock/project"
        )
        return decodeLines(doc.wireJSONL)
    }

    @Test("wire.jsonl opens with a metadata record carrying the protocol version")
    func buildsWireMetadata() {
        let lines = makeWireLines()
        #expect(lines.first?["type"] as? String == "metadata")
        #expect(lines.first?["protocol_version"] as? String == "1.4")
    }

    @Test("a user message becomes a turn.prompt with origin.kind=user")
    func buildsWireTurnPrompt() throws {
        let prompt = try #require(makeWireLines().first { $0["type"] as? String == "turn.prompt" })
        let promptOrigin = prompt["origin"] as? [String: Any]
        #expect(promptOrigin?["kind"] as? String == "user")
    }

    @Test("a user message also becomes a context.append_message with origin.kind=user")
    func buildsWireAppendMessage() throws {
        let appendMsg = try #require(makeWireLines().first { $0["type"] as? String == "context.append_message" })
        let message = appendMsg["message"] as? [String: Any]
        #expect(message?["role"] as? String == "user")
        #expect((message?["origin"] as? [String: Any])?["kind"] as? String == "user")
    }

    @Test("an assistant message becomes a turnId-linked step.begin + content.part pair")
    func buildsWireAssistantLoopEvents() throws {
        let loopEvents = makeWireLines().filter { $0["type"] as? String == "context.append_loop_event" }
        #expect(loopEvents.count == 2) // step.begin + content.part(text)

        let stepBegin = try #require(loopEvents.first)
        let stepEvent = stepBegin["event"] as? [String: Any]
        #expect(stepEvent?["type"] as? String == "step.begin")
        #expect(stepEvent?["turnId"] as? String == "0")

        let partEvent = (loopEvents.last?["event"]) as? [String: Any]
        #expect(partEvent?["turnId"] as? String == "0")
        #expect(partEvent?["stepUuid"] as? String == stepEvent?["uuid"] as? String)
        let part = partEvent?["part"] as? [String: Any]
        #expect(part?["type"] as? String == "text")
        #expect(part?["text"] as? String == "Hello!")
    }

    @Test("step increments per assistant message within a turn, sharing the same turnId")
    func stepIncrementsWithinTurn() {
        let convo = TestFixtures.makeConversation(
            id: "kimi-step",
            messages: [
                UnifiedMessage(role: .user, content: "Hi", timestamp: TestFixtures.sampleDate),
                UnifiedMessage(role: .assistant, content: "First", timestamp: TestFixtures.sampleDate),
                UnifiedMessage(role: .assistant, content: "Second", timestamp: TestFixtures.sampleDate),
            ]
        )
        let doc = KimiCodeWireBuilder().makeDocument(
            conversation: convo,
            sessionId: "session_step",
            sessionDirPath: "/d",
            workDir: "/w"
        )
        let lines = decodeLines(doc.wireJSONL)
        let contentParts = lines
            .filter { $0["type"] as? String == "context.append_loop_event" }
            .compactMap { $0["event"] as? [String: Any] }
            .filter { $0["type"] as? String == "content.part" }

        #expect(contentParts.count == 2)
        let turnIds = Set(contentParts.compactMap { $0["turnId"] as? String })
        #expect(turnIds == ["0"]) // both assistant messages belong to the same (only) user turn
        let steps = contentParts.compactMap { $0["step"] as? Int }
        #expect(steps == [1, 2])
    }

    @Test("state.json embeds the migration meta and a main agent")
    func buildsState() throws {
        let convo = TestFixtures.makeConversation(id: "kimi-state", source: .codex)
        let builder = KimiCodeWireBuilder()
        let doc = builder.makeDocument(
            conversation: convo,
            sessionId: "session_xyz",
            sessionDirPath: "/home/.kimi-code/sessions/wd_project_deadbeef0000/session_xyz",
            workDir: "/test/project"
        )
        let state = try #require(
            (try? JSONSerialization.jsonObject(with: Data(doc.stateJSON.utf8))) as? [String: Any]
        )
        #expect(state["workDir"] as? String == "/test/project")
        let custom = state["custom"] as? [String: Any]
        let meta = custom?["ctxmv_migration"] as? [String: Any]
        #expect(meta?["type"] as? String == MigrationMeta.migrationType)
        #expect(meta?["originId"] as? String == "kimi-state")
        #expect(meta?["originSource"] as? String == "codex")
        let agents = state["agents"] as? [String: Any]
        let mainAgent = agents?["main"] as? [String: Any]
        #expect(mainAgent?["type"] as? String == "main")
        // Native kimi writes an explicit null; the key must be present.
        #expect(mainAgent?["parentAgentId"] is NSNull)
    }

    @Test("system and tool messages are skipped")
    func skipsSystemAndTool() {
        let convo = TestFixtures.makeConversation(
            id: "kimi-skip",
            messages: [
                UnifiedMessage(role: .system, content: "sys", timestamp: nil),
                UnifiedMessage(role: .user, content: "Hi", timestamp: nil),
                UnifiedMessage(role: .tool, content: "tool", timestamp: nil),
                UnifiedMessage(role: .assistant, content: "Yo", timestamp: nil),
            ]
        )
        let doc = KimiCodeWireBuilder().makeDocument(
            conversation: convo,
            sessionId: "session_s",
            sessionDirPath: "/d",
            workDir: "/w"
        )
        let lines = decodeLines(doc.wireJSONL)
        #expect(lines.count { $0["type"] as? String == "turn.prompt" } == 1)
        #expect(!doc.wireJSONL.contains("\"sys\""))
        #expect(!doc.wireJSONL.contains("\"tool\""))
    }

    @Test("injected noise is a context-only append_message, never a turn.prompt")
    func noiseBecomesInjection() throws {
        let convo = TestFixtures.makeConversation(
            id: "kimi-noise",
            source: .claudeCode,
            messages: [
                UnifiedMessage(role: .user, content: "Real question", timestamp: TestFixtures.sampleDate),
                UnifiedMessage(
                    role: .user,
                    content: "<task-notification><summary>Review found 2 issues</summary></task-notification>",
                    timestamp: TestFixtures.sampleDate
                ),
                UnifiedMessage(role: .assistant, content: "Answer", timestamp: TestFixtures.sampleDate),
            ]
        )
        let doc = KimiCodeWireBuilder().makeDocument(
            conversation: convo,
            sessionId: "session_noise",
            sessionDirPath: "/d",
            workDir: "/w"
        )
        let lines = decodeLines(doc.wireJSONL)

        // Only the genuine prompt opens a turn.
        #expect(lines.count { $0["type"] as? String == "turn.prompt" } == 1)
        let appendMessages = lines
            .filter { $0["type"] as? String == "context.append_message" }
            .compactMap { $0["message"] as? [String: Any] }
        #expect(appendMessages.count == 2)
        let injected = try #require(appendMessages.first {
            (($0["content"] as? [[String: Any]])?.first?["text"] as? String)?.contains("[Subagent]") == true
        })
        #expect((injected["origin"] as? [String: Any])?["kind"] as? String == "injection")

        // Noise must not open a turn: the assistant reply stays on the real prompt's turn.
        let stepBegin = lines
            .compactMap { $0["event"] as? [String: Any] }
            .first { $0["type"] as? String == "step.begin" }
        #expect(stepBegin?["turnId"] as? String == "0")
    }

    @Test("title and lastPrompt skip injected noise")
    func stateSkipsNoise() throws {
        let convo = TestFixtures.makeConversation(
            id: "kimi-title-noise",
            source: .claudeCode,
            messages: [
                UnifiedMessage(
                    role: .user,
                    content: "<task-notification><summary>noise</summary></task-notification>",
                    timestamp: TestFixtures.sampleDate
                ),
                UnifiedMessage(role: .user, content: "Genuine prompt", timestamp: TestFixtures.sampleDate),
                UnifiedMessage(
                    role: .user,
                    content: "<command-name>/review</command-name>",
                    timestamp: TestFixtures.sampleDate
                ),
            ]
        )
        let doc = KimiCodeWireBuilder().makeDocument(
            conversation: convo,
            sessionId: "session_t",
            sessionDirPath: "/d",
            workDir: "/w"
        )
        let state = try #require(
            (try? JSONSerialization.jsonObject(with: Data(doc.stateJSON.utf8))) as? [String: Any]
        )
        #expect(state["title"] as? String == "Genuine prompt")
        #expect(state["lastPrompt"] as? String == "Genuine prompt")
    }
}
