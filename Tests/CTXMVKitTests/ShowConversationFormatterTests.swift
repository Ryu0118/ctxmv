@testable import CTXMVKit
import Foundation
import Testing

struct ShowConversationFormatterTests {
    @Test("compact mode omits structured XML blocks")
    func compactModeOmitsStructuredBlocks() {
        let conversation = TestFixtures.makeConversation(
            messages: [
                UnifiedMessage(role: .user, content: "Hello", timestamp: TestFixtures.sampleDate),
                UnifiedMessage(
                    role: .assistant,
                    content: """
                    Before

                    ```xml
                    <root>
                      <node />
                    </root>
                    ```

                    After
                    """,
                    timestamp: TestFixtures.sampleDate
                ),
            ]
        )

        let result = ShowConversationFormatter(raw: false).format(conversation)

        #expect(result.contains("Session: \(conversation.id)"))
        #expect(result.contains("View:     compact"))
        #expect(result.contains("[XML block omitted: 3 lines, use --raw to show full content]"))
        #expect(!result.contains("```xml"))
        #expect(result.contains("  Before"))
        #expect(result.contains("  After"))
        #expect(result.components(separatedBy: String(repeating: "-", count: 88)).count == 2)
    }

    @Test("raw mode preserves structured XML blocks")
    func rawModePreservesStructuredBlocks() {
        let conversation = TestFixtures.makeConversation(
            messages: [
                UnifiedMessage(
                    role: .assistant,
                    content: """

                    <alpha>
                    <beta>
                    </beta>

                    tail

                    """,
                    timestamp: TestFixtures.sampleDate
                ),
            ]
        )

        let result = ShowConversationFormatter(raw: true).format(conversation)

        #expect(result.contains("View:     raw"))
        #expect(result.contains("  <alpha>"))
        #expect(result.contains("  <beta>"))
        #expect(result.contains("  </beta>"))
        #expect(result.contains("  tail"))
        #expect(!result.contains("[XML-like tag block omitted"))
    }
}
