@testable import CTXMVKit
import Foundation
import Testing

struct CursorAgentContentDecoderTests {
    @Test("decodes single user_query wrapper")
    func decodeSingle() {
        let input = CursorAgentTag.userQuery.wrap("hello")
        let result = CursorAgentContentDecoder.decode(input)
        #expect(result == "hello")
    }

    @Test("decodes nested user_query wrappers")
    func decodeNested() {
        let inner = CursorAgentTag.userQuery.wrap("inner")
        let input = CursorAgentTag.userQuery.wrap("  \(inner)\n  outer")
        let result = CursorAgentContentDecoder.decode(input)
        #expect(result.contains("inner"))
        #expect(result.contains("outer"))
        #expect(!result.contains(CursorAgentTag.userQuery.openingTag))
    }

    @Test("leaves non-wrapper content unchanged")
    func unchanged() {
        let input = "plain text without cursor tags"
        let result = CursorAgentContentDecoder.decode(input)
        #expect(result == input)
    }
}

struct UnifiedMessageCursorDecodingTests {
    @Test("decodedContent applies Cursor decoder for cursor source")
    func appliesCursorDecoder() {
        let msg = UnifiedMessage(
            role: .user,
            content: CursorAgentTag.userQuery.wrap("decoded query"),
            timestamp: nil
        )
        #expect(msg.decodedContent(for: .cursor) == "decoded query")
    }
}
