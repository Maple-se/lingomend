@testable import CoachCore
import Foundation
import XCTest

private struct ExpressionTransport: CoachingHTTPTransport {
    let result: CoachingHTTPResult
    func send(_ request: URLRequest) async throws -> CoachingHTTPResult { result }
}

private struct SlowExpressionTransport: CoachingHTTPTransport {
    func send(_ request: URLRequest) async throws -> CoachingHTTPResult {
        try await Task.sleep(for: .seconds(60))
        throw CoachingProviderError.network
    }
}

final class ExpressionProviderTests: XCTestCase {
    private let input = ExpressionRequest(source: "轻载条件下", left: "This works ", right: ".", context: .academic)
    private let valid = "{\"status\":\"suggest\",\"replacement\":\"under light-load conditions\"}"

    private func provider(_ content: String, status: Int = 200, finish: String = "stop",
                          refusal: String? = nil) throws -> DeepSeekExpressionProvider {
        var message: [String: Any] = ["content": content]
        if let refusal { message["refusal"] = refusal }
        let data = try JSONSerialization.data(withJSONObject: ["choices": [["message": message, "finish_reason": finish]]])
        return DeepSeekExpressionProvider(apiKey: "synthetic-test-key",
            transport: ExpressionTransport(result: CoachingHTTPResult(data: data, statusCode: status)))
    }

    func testDeepSeekWireFormatIsBoundedNonThinkingAndNonStreaming() throws {
        let provider = DeepSeekExpressionProvider(apiKey: "synthetic-test-key")
        let request = try provider.makeRequest(input)
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-test-key")
        XCTAssertEqual(request.timeoutInterval, 12)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "deepseek-flash")
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertEqual(body["thinking"] as? [String: String], ["type": "disabled"])
        XCTAssertEqual(body["response_format"] as? [String: String], ["type": "json_object"])
        XCTAssertEqual(body["max_tokens"] as? Int, 192)
        XCTAssertNil(body["tools"]); XCTAssertNil(body["store"])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertTrue(messages[0]["content"]!.contains("JSON"))
        let content = try XCTUnwrap(messages[1]["content"]?.data(using: .utf8))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: content) as? [String: String])
        XCTAssertEqual(Set(payload.keys), ["source", "left", "right", "context", "correction_level"])
        XCTAssertEqual(payload["source"], input.source)
        XCTAssertFalse(String(decoding: request.httpBody!, as: UTF8.self).contains("synthetic-test-key"))
    }

    func testCandidateAndExplicitAbstention() async throws {
        let result = try await provider(valid).candidate(input)
        XCTAssertEqual(result, "under light-load conditions")
        let abstention = try await provider("{\"status\":\"abstain\",\"replacement\":\"\"}").candidate(input)
        XCTAssertNil(abstention)
    }

    func testRejectsInvalidShapesAndCandidateText() async throws {
        let outputs = ["", "```json\n\(valid)\n```", "{}",
            "{\"status\":\"suggest\",\"replacement\":\"under light-load conditions\",\"range\":0}",
            "{\"status\":\"abstain\",\"replacement\":\"English\"}",
            "{\"status\":\"unknown\",\"replacement\":\"English\"}"]
        for content in outputs {
            do { _ = try await provider(content).candidate(input); XCTFail("Expected rejection") }
            catch { XCTAssertEqual(error as? CoachingProviderError, .invalidResponse) }
        }
        for replacement in ["", "   ", " English", "English\nphrase", "English\tphrase", "轻载条件下",
                            "English\u{200B}phrase", String(repeating: "a", count: 241),
                            "This works under light-load conditions."] {
            let content = String(decoding: try JSONSerialization.data(withJSONObject:
                ["status": "suggest", "replacement": replacement]), as: UTF8.self)
            do { _ = try await provider(content).candidate(input); XCTFail("Expected rejection") }
            catch { XCTAssertEqual(error as? CoachingProviderError, .invalidResponse) }
        }
    }

    func testRefusedAndTruncatedResultsFailClosed() async throws {
        for (finish, refusal, expected) in [("length", nil, CoachingProviderError.incompleteResponse),
                                           ("stop", "refused", .refused), ("tool_calls", nil, .incompleteResponse)] {
            do { _ = try await provider(valid, finish: finish, refusal: refusal).candidate(input); XCTFail("Expected rejection") }
            catch { XCTAssertEqual(error as? CoachingProviderError, expected) }
        }
    }

    func testHTTPFailuresNeverExposeTheirBodies() async throws {
        for (status, expected) in [(401, CoachingProviderError.unauthorized), (403, .unauthorized),
                                  (429, .rateLimited), (402, .httpStatus(402)), (503, .httpStatus(503))] {
            do { _ = try await provider("sensitive response body", status: status).candidate(input); XCTFail("Expected rejection") }
            catch { XCTAssertEqual(error as? CoachingProviderError, expected) }
        }
    }

    func testExplanationHasSeparateBudgetAndLocalAnchors() async throws {
        let provider = try provider("""
        {"status":"explain","reason_zh":"描述轻载工况。","category":"terminology","acceptable_variants":[]}
        """)
        let request = try provider.makeRequest(input, replacement: "under light-load conditions")
        XCTAssertEqual(request.timeoutInterval, 30)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertEqual(body["max_tokens"] as? Int, 512)
        let point = try await provider.explain(input, replacement: "under light-load conditions")
        XCTAssertEqual(point?.source, input.source)
        XCTAssertEqual(point?.target, "under light-load conditions")
        XCTAssertEqual(point?.category, .terminology)
    }

    func testExplanationCannotReturnANewTargetOrUnsafeVariants() async throws {
        for content in [
            "{\"status\":\"explain\",\"reason_zh\":\"原因\",\"category\":\"unknown\",\"acceptable_variants\":[]}",
            "{\"status\":\"explain\",\"reason_zh\":\"\",\"category\":\"tone\",\"acceptable_variants\":[]}",
            "{\"status\":\"explain\",\"reason_zh\":\"原因\",\"category\":\"tone\",\"acceptable_variants\":[\"中文\"]}",
            "{\"status\":\"explain\",\"reason_zh\":\"原因\",\"category\":\"tone\",\"acceptable_variants\":[],\"target\":\"new edit\"}"
        ] {
            do { _ = try await provider(content).explain(input, replacement: "under light-load conditions"); XCTFail("Expected rejection") }
            catch { XCTAssertEqual(error as? CoachingProviderError, .invalidResponse) }
        }
        let point = try await provider("{\"status\":\"abstain\",\"reason_zh\":\"\",\"category\":\"tone\",\"acceptable_variants\":[]}")
            .explain(input, replacement: "under light-load conditions")
        XCTAssertNil(point)
    }

    func testInputAndCredentialLimitsRejectBeforeNetworking() throws {
        let provider = DeepSeekExpressionProvider(apiKey: "synthetic-test-key")
        for input in [ExpressionRequest(source: ""), ExpressionRequest(source: String(repeating: "中", count: 41)),
                      ExpressionRequest(source: "中文", left: String(repeating: "a", count: 201)),
                      ExpressionRequest(source: "中文", right: String(repeating: "a", count: 201))] {
            XCTAssertThrowsError(try provider.makeRequest(input))
        }
        for key in ["", "  ", "key\nheader"] {
            XCTAssertThrowsError(try DeepSeekExpressionProvider(apiKey: key).makeRequest(input))
        }
        XCTAssertThrowsError(try DeepSeekExpressionProvider(configuration: ProviderConfiguration(
            baseURL: "https://api.deepseek.com", model: "deepseek-flash", outputFormat: .jsonSchema), apiKey: "test").makeRequest(input))
    }

    func testHardDeadlineCancelsSlowTransport() async throws {
        var request = URLRequest(url: URL(string: "https://example.invalid")!)
        request.timeoutInterval = 0.02
        do {
            _ = try await ChatCompletionClient(transport: SlowExpressionTransport()).content(for: request)
            XCTFail("Expected timeout")
        } catch { XCTAssertEqual(error as? CoachingProviderError, .timedOut) }
    }

    func testCancellationDoesNotBecomeAServiceError() async throws {
        let provider = DeepSeekExpressionProvider(apiKey: "test", transport: SlowExpressionTransport())
        let input = input
        let task = Task { try await provider.candidate(input) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testOfflineDemoSupportsOnlyItsDocumentedSample() async throws {
        let provider = DemoExpressionProvider()
        let candidate = try await provider.candidate(input)
        XCTAssertEqual(candidate, "under light-load conditions")
        let unknown = try await provider.candidate(ExpressionRequest(source: "提高效率"))
        XCTAssertNil(unknown)
    }
}
