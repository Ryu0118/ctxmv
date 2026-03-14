import Foundation

/// Extracts messages from Cursor store.db blob data.
/// Handles both raw JSON blobs (0x7B prefix) and protobuf-wrapped blobs.
enum CursorBlobParser {
    private static let decoder = JSONDecoder()

    static func extractMessage(from data: Data) -> UnifiedMessage? {
        guard !data.isEmpty else { return nil }

        let blobMessage: CursorBlobMessage?

        if data[0] == 0x7B { // '{'
            blobMessage = try? decoder.decode(CursorBlobMessage.self, from: data)
        } else {
            let text = String(decoding: data, as: UTF8.self)
            guard let jsonStr = findEmbeddedJSONString(in: text),
                  let jsonData = jsonStr.data(using: .utf8) else { return nil }
            blobMessage = try? decoder.decode(CursorBlobMessage.self, from: jsonData)
        }

        guard let message = blobMessage,
              let role = MessageRole(rawValue: message.role),
              role == .user || role == .assistant else { return nil }
        let content = message.content.textContent
        guard !content.isEmpty else { return nil }
        return UnifiedMessage(role: role, content: content, timestamp: nil)
    }

    static func findEmbeddedJSONString(in text: String) -> String? {
        for needle in ["{\"role\":", "{\"id\":\""] {
            guard let startRange = text.range(of: needle) else { continue }
            let startIndex = startRange.lowerBound
            var depth = 0
            var endIndex = startIndex

            for idx in text[startIndex...].indices {
                let character = text[idx]
                if character == "{" { depth += 1 }
                else if character == "}" { depth -= 1 }
                if depth == 0, idx > startIndex {
                    endIndex = text.index(after: idx)
                    break
                }
            }

            guard endIndex > startIndex else { continue }
            return String(text[startIndex ..< endIndex])
        }
        return nil
    }

    static func hexDecode(_ hex: String) -> Data? {
        let normalized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count.isMultiple(of: 2) else { return nil }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(normalized.count / 2)

        var index = normalized.startIndex
        while index < normalized.endIndex {
            let next = normalized.index(index, offsetBy: 2)
            guard let byte = UInt8(normalized[index ..< next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }

        return Data(bytes)
    }
}
