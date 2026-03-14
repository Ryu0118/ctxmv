import Foundation

/// Enumerates supported normalized content block kinds.
enum ContentBlockType: String, Codable, Sendable {
    case text
    case outputText = "output_text"
    case inputText = "input_text"
}

/// Shared content block used by Claude Code, Cursor, and Codex message schemas.
/// Only `type` and `text` are relevant for migration/display; other fields are ignored during decode.
struct ContentBlock: Codable, Sendable {
    let type: String
    let text: String?

    init(type: String, text: String? = nil) {
        self.type = type; self.text = text
    }

    init(type: ContentBlockType, text: String? = nil) {
        self.type = type.rawValue
        self.text = text
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        text = try container.decodeIfPresent(String.self, forKey: .text)
    }

    private enum CodingKeys: String, CodingKey {
        case type, text
    }

    var blockType: ContentBlockType? {
        ContentBlockType(rawValue: type)
    }
}

/// Content that is either a plain string or an array of typed blocks.
/// Shared by Claude Code and Cursor message schemas.
enum TextOrBlocks: Codable, Sendable {
    case text(String)
    case blocks([ContentBlock])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            self = .text(str)
        } else if let blocks = try? container.decode([ContentBlock].self) {
            self = .blocks(blocks)
        } else {
            self = .text("")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .text(str):
            try container.encode(str)
        case let .blocks(blocks):
            try container.encode(blocks)
        }
    }

    /// Extract all text content as a single string.
    var textContent: String {
        switch self {
        case let .text(str):
            return str
        case let .blocks(blocks):
            return blocks.compactMap { block -> String? in
                guard block.blockType == .text else { return nil }
                return block.text
            }.joined(separator: "\n")
        }
    }
}
