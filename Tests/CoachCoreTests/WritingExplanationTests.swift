import Foundation
import XCTest
@testable import CoachCore

private struct WritingExplanationTransport: CoachingHTTPTransport {
    let result: CoachingHTTPResult
    func send(_ request: URLRequest) async throws -> CoachingHTTPResult { result }
}

final class WritingExplanationTests: XCTestCase {
    private func request() throws -> WritingExplanationRequest {
        try WritingExplanationRequest(
            request: SentenceRequest(target: "I very like 这个方案."),
            replacement: "I really like this approach.")
    }

    private func provider(_ content: String) throws -> DeepSeekSentenceProvider {
        let message: [String: Any] = ["content": content]
        let data = try JSONSerialization.data(withJSONObject: [
            "choices": [["message": message, "finish_reason": "stop"]]
        ])
        return DeepSeekSentenceProvider(apiKey: "synthetic-test-key",
            transport: WritingExplanationTransport(result: CoachingHTTPResult(data: data, statusCode: 200)))
    }

    func testRequestWireIsBoundedAndKeepsLocalAnchors() throws {
        let input = try request()
        let provider = DeepSeekSentenceProvider(apiKey: "synthetic-test-key")
        let request = try provider.makeExplanationRequest(input)
        XCTAssertEqual(request.timeoutInterval, 30)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "deepseek-flash")
        XCTAssertEqual(body["max_tokens"] as? Int, 512)
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertEqual(body["thinking"] as? [String: String], ["type": "disabled"])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        let payloadData = try XCTUnwrap(messages[1]["content"]?.data(using: .utf8))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: payloadData) as? [String: String])
        XCTAssertEqual(Set(payload.keys), ["target", "left", "right", "replacement", "intent_hint", "extent"])
        XCTAssertEqual(payload["target"], input.request.target)
        XCTAssertEqual(payload["replacement"], input.replacement)
        XCTAssertFalse(String(decoding: request.httpBody!, as: UTF8.self).contains("synthetic-test-key"))
    }

    func testValidExplanationAndExplicitAbstention() async throws {
        let input = try request()
        let explanation = try await provider(
            "{\"status\":\"explain\",\"reason_zh\":\"like 通常不和 very 这样搭配。\",\"category\":\"naturalness\",\"acceptable_variants\":[]}")
            .explain(input)
        XCTAssertEqual(explanation?.category, .naturalness)
        XCTAssertTrue(explanation?.reason.contains("very") == true)
        let abstain = try await provider(
            "{\"status\":\"abstain\",\"reason_zh\":\"\",\"category\":\"naturalness\",\"acceptable_variants\":[]}")
            .explain(input)
        XCTAssertNil(abstain)
    }

    func testInvalidExplanationShapesFailClosed() async throws {
        let input = try request()
        let outputs = [
            "{}",
            "{\"status\":\"explain\",\"reason_zh\":\"\",\"category\":\"grammar\",\"acceptable_variants\":[]}",
            "{\"status\":\"explain\",\"reason_zh\":\"原因\",\"category\":\"unknown\",\"acceptable_variants\":[]}",
            "{\"status\":\"explain\",\"reason_zh\":\"原因\",\"category\":\"grammar\",\"acceptable_variants\":[\"中文\"]}",
            "{\"status\":\"explain\",\"reason_zh\":\"原因\",\"category\":\"grammar\",\"acceptable_variants\":[\"one\",\"two\",\"three\",\"four\"]}",
            "{\"status\":\"explain\",\"reason_zh\":\"原因\",\"category\":\"grammar\",\"acceptable_variants\":[],\"target\":\"new edit\"}"
        ]
        for output in outputs {
            do {
                _ = try await provider(output).explain(input)
                XCTFail("Expected invalid explanation to be rejected: \(output)")
            } catch {
                XCTAssertEqual(error as? CoachingProviderError, .invalidResponse)
            }
        }
    }

    func testExplanationRequestRejectsUnchangedOrOversizedCandidates() throws {
        let sentence = try SentenceRequest(target: "A short sentence.")
        XCTAssertThrowsError(try WritingExplanationRequest(request: sentence, replacement: sentence.target))
        XCTAssertThrowsError(try WritingExplanationRequest(
            request: SentenceRequest(target: String(repeating: "a", count: 601)), replacement: "A"))
        XCTAssertThrowsError(try DeepSeekSentenceProvider(apiKey: "").makeExplanationRequest(try request()))
    }

    func testDemoExplanationIsSeparateFromAcceptanceCandidate() async throws {
        let input = try request()
        let result = try await DemoSentenceProvider().explain(input)
        XCTAssertEqual(result?.category, .naturalness)
        XCTAssertEqual(result?.acceptableVariants, [])
    }
}
