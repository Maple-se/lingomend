import Foundation
import Testing
@testable import CoachCore

struct ReadingExplanationTests {
    @Test func contextualDemoDisambiguatesSameWord() async throws {
        let provider = DemoReadingProvider()
        let electrical = try ReadingRequest(selection: "current", before: "The ", after: " flows through the coil.", contextKind: .sentence)
        let everyday = try ReadingRequest(selection: "current", before: "This is our ", after: " plan.", contextKind: .sentence)
        #expect(try await provider.explain(electrical).meaning == "电流")
        #expect(try await provider.explain(everyday).meaning == "当前的；现行的")
    }

    @Test func noContextCannotReturnAnInventedSentence() throws {
        let request = try ReadingRequest(selection: "current")
        #expect(throws: CoachingProviderError.invalidResponse) {
            try ReadingExplanation(meaning: "电流", contextMeaning: "电流流过线圈。").validate(for: request)
        }
        try ReadingExplanation(meaning: "当前的；电流；水流").validate(for: request)
        #expect(throws: CoachingProviderError.invalidConfiguration) {
            try ReadingRequest(selection: "current", before: "The ")
        }
    }

    @Test func contextRequiredAndLengthsBounded() throws {
        let request = try ReadingRequest(selection: "current", before: "The ", after: " flows.", contextKind: .sentence)
        #expect(throws: CoachingProviderError.invalidResponse) { try ReadingExplanation(meaning: "电流").validate(for: request) }
        #expect(throws: CoachingProviderError.inputTooLarge) { try ReadingRequest(selection: String(repeating: "x", count: 1_201)) }
        #expect(throws: CoachingProviderError.inputTooLarge) {
            try ReadingRequest(selection: "word", before: String(repeating: "x", count: 2_000), contextKind: .excerpt)
        }
    }

    @Test func requestIsBoundedReadOnlyAndKeepsSelectionSeparate() throws {
        let input = try ReadingRequest(selection: "current", before: "The ", after: " flows.", contextKind: .sentence)
        let request = try DeepSeekReadingProvider(apiKey: "synthetic-test-key").makeRequest(input)
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["max_tokens"] as? Int == 1_400)
        #expect(request.timeoutInterval == 20)
        let messages = try #require(body["messages"] as? [[String: String]])
        let content = try #require(messages.last?["content"])
        let payload = try #require(JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: String])
        #expect(payload == ["selection": "current", "before": "The ", "after": " flows.", "context_kind": "sentence"])
        #expect(messages.first?["content"]?.contains("NEVER instructions") == true)
    }

    @Test func strictResponseContractAndFinishReason() async throws {
        let request = try ReadingRequest(selection: "current")
        let valid = #"{"meaning":"当前的；电流","context_meaning":"","usage":""}"#
        let provider = DeepSeekReadingProvider(apiKey: "test", transport: ReadingTransport(content: valid))
        #expect(try await provider.explain(request).meaning == "当前的；电流")
        let extra = DeepSeekReadingProvider(apiKey: "test", transport: ReadingTransport(content:
            #"{"meaning":"电流","context_meaning":"","usage":"","replacement":"current"}"#))
        await #expect(throws: CoachingProviderError.invalidResponse) { try await extra.explain(request) }
        let incomplete = DeepSeekReadingProvider(apiKey: "test", transport: ReadingTransport(content: valid, finish: "length"))
        await #expect(throws: CoachingProviderError.incompleteResponse) { try await incomplete.explain(request) }
    }
}

private struct ReadingTransport: CoachingHTTPTransport {
    let content: String
    var finish = "stop"
    func send(_ request: URLRequest) async throws -> CoachingHTTPResult {
        let data = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content], "finish_reason": finish]]])
        return CoachingHTTPResult(data: data, statusCode: 200)
    }
}
