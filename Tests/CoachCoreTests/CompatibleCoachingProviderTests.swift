import CoachCore
import Foundation
import XCTest

private struct FixedTransport: CoachingHTTPTransport {
    let result: CoachingHTTPResult
    func send(_ request: URLRequest) async throws -> CoachingHTTPResult { result }
}

final class CompatibleCoachingProviderTests: XCTestCase {
    private let configuration = ProviderConfiguration(model: "test-model")
    private func provider(_ content: String, status: Int = 200, finish: String = "stop", refusal: String? = nil) throws -> CompatibleCoachingProvider {
        var message: [String: Any] = ["content": content]
        if let refusal { message["refusal"] = refusal }
        let data = try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": finish, "message": message]]])
        return CompatibleCoachingProvider(configuration: configuration,
            transport: FixedTransport(result: CoachingHTTPResult(data: data, statusCode: status)))
    }
    private let validJSON = """
    {"natural_text":"This works under light-load conditions.","meaning_preserved":true,
    "learning_points":[{"source":"轻载条件下","target":"under light-load conditions",
    "reason_zh":"用于描述轻载工况。","category":"terminology","acceptable_variants":[]}],"warnings":[]}
    """

    func testValidStructuredResponseWithNoRealNetwork() async throws {
        let result = try await provider(validJSON).suggest(CoachRequest(sourceText: "This works 轻载条件下."))
        XCTAssertEqual(result.naturalText, "This works under light-load conditions.")
        XCTAssertEqual(result.learningPoints.count, 1)
    }
    func testRequestUsesJSONAndDoesNotContainUnrelatedContext() throws {
        let request = try CompatibleCoachingProvider(configuration: configuration, apiKey: "synthetic-test-key")
            .makeRequest(CoachRequest(sourceText: "This works 轻载条件下.", context: .academic, correctionLevel: .correct))
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-test-key")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual((body["response_format"] as? [String: String])?["type"], "json_object")
        XCTAssertFalse(String(decoding: request.httpBody!, as: UTF8.self).contains("applicationIdentifier"))
    }
    func testOutputFormatIsExplicitAndNoAutomaticRetry() throws {
        for format in ProviderOutputFormat.allCases {
            let provider = CompatibleCoachingProvider(configuration: ProviderConfiguration(model: "test", outputFormat: format))
            let request = try provider.makeRequest(CoachRequest(sourceText: "Example."))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            XCTAssertEqual(body["response_format"] == nil, format == .promptOnly)
        }
    }
    func testEndpointRejectsUnsafeURLsAndEmptyModel() throws {
        for url in ["http://example.com/v1", "https://user:password@example.com/v1", "https://example.com/v1?key=value", "file:///tmp/model"] {
            XCTAssertThrowsError(try ProviderConfiguration(baseURL: url, model: "test").endpoint())
        }
        XCTAssertThrowsError(try ProviderConfiguration().endpoint())
        XCTAssertEqual(try ProviderConfiguration(baseURL: "http://127.0.0.1:1234/v1/", model: "test").endpoint().path,
                       "/v1/chat/completions")
    }
    func testMalformedRefusedAndTruncatedResponsesFailClosed() async throws {
        for (content, finish, refusal) in [("```json\n\(validJSON)\n```", "stop", nil),
                                          (validJSON, "length", nil), (validJSON, "stop", "refused")] {
            do {
                _ = try await provider(content, finish: finish, refusal: refusal)
                    .suggest(CoachRequest(sourceText: "This works 轻载条件下."))
                XCTFail("Expected rejection")
            } catch { XCTAssertTrue(error is CoachingProviderError) }
        }
    }
    func testUnauthorizedAndUnanchoredPointsFailClosed() async throws {
        do {
            _ = try await provider(validJSON, status: 401).suggest(CoachRequest(sourceText: "This works 轻载条件下."))
            XCTFail("Expected unauthorized")
        } catch { XCTAssertEqual(error as? CoachingProviderError, .unauthorized) }
        do {
            _ = try await provider(validJSON).suggest(CoachRequest(sourceText: "Unrelated English."))
            XCTFail("Expected unanchored point")
        } catch { XCTAssertEqual(error as? CoachResponseValidationError, .unanchoredLearningPoint) }
    }
}
