@testable import CTXMVKit
import Foundation
import Testing

struct JSONLParserTests {
    struct SimpleEntry: Codable {
        let type: String
        let message: String
    }

    struct TestCase: CustomTestStringConvertible {
        let description: String
        let input: String
        let isValid: Bool

        var testDescription: String {
            description
        }

        static let allCases: [TestCase] = [
            TestCase(description: "valid JSON line", input: #"{"type":"user","message":"hello"}"#, isValid: true),
            TestCase(description: "blank line", input: "", isValid: false),
            TestCase(description: "whitespace only", input: "   ", isValid: false),
            TestCase(description: "invalid JSON", input: "not json at all", isValid: false),
            TestCase(description: "missing required field", input: #"{"type":"user"}"#, isValid: false),
        ]
    }

    @Test("decodes JSONL lines", arguments: TestCase.allCases)
    func decodeLine(_ testCase: TestCase) throws {
        let result = JSONLParser.decodeLine(testCase.input, as: SimpleEntry.self)
        if testCase.isValid {
            let entry = try #require(result)
            #expect(entry.type == "user")
            #expect(entry.message == "hello")
        } else {
            #expect(result == nil)
        }
    }
}

struct DateUtilsTests {
    struct TestCase: CustomTestStringConvertible {
        let description: String
        let input: String
        let isValid: Bool

        var testDescription: String {
            description
        }

        static let allCases: [TestCase] = [
            TestCase(description: "fractional seconds", input: "2024-03-09T12:30:00.123Z", isValid: true),
            TestCase(description: "no fractional seconds", input: "2024-03-09T12:30:00Z", isValid: true),
            TestCase(description: "garbage input", input: "not-a-date", isValid: false),
            TestCase(description: "empty string", input: "", isValid: false),
        ]
    }

    @Test("parses ISO 8601 dates", arguments: TestCase.allCases)
    func parseISO8601(_ testCase: TestCase) throws {
        let result = DateUtils.parseISO8601(testCase.input)
        if testCase.isValid {
            _ = try #require(result)
        } else {
            #expect(result == nil)
        }
    }
}
