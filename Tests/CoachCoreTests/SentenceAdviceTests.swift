@testable import CoachCore
import Foundation
import XCTest

private struct SentenceTransport: CoachingHTTPTransport {
    let data: Data
    let status: Int
    func send(_ request: URLRequest) async throws -> CoachingHTTPResult { CoachingHTTPResult(data: data, statusCode: status) }
}

final class SentenceAdviceTests: XCTestCase {
    private func provider(_ content: String, finish: String = "stop", status: Int = 200) throws -> DeepSeekSentenceProvider {
        let data = try JSONSerialization.data(withJSONObject:
            ["choices": [["message": ["content": content], "finish_reason": finish]]])
        return DeepSeekSentenceProvider(apiKey: "synthetic-test-key", transport: SentenceTransport(data: data, status: status))
    }

    func testLocalIntentUsesSentenceContextForSelectedChinese() throws {
        XCTAssertEqual(try SentenceRequest(target: "负责", left: "I am ", right: " this project.").intent, .fillGaps)
        XCTAssertEqual(try SentenceRequest(target: "She go home.").intent, .correctEnglish)
        XCTAssertEqual(try SentenceRequest(target: "可能降低损耗。").intent, .translate)
        XCTAssertEqual(try SentenceRequest(target: "I visited 北京.").intent, .fillGaps) // A hint, not a claim that 北京 is a gap.
    }

    func testRequestLimitsAndNonProseGuardBeforeTransport() throws {
        for target in ["", " ", String(repeating: "a", count: 601), "x = 1", "https://example.com", "me@example.com",
                       "`code`", "{ value }", "One\nTwo", "test\tvalue", "123"] {
            XCTAssertThrowsError(try SentenceRequest(target: target))
        }
        XCTAssertThrowsError(try SentenceRequest(target: "词", left: String(repeating: "a", count: 600)))
    }

    func testWireIncludesOnlyOneBoundedSentenceAndNoPrivateMetadata() throws {
        let provider = DeepSeekSentenceProvider(apiKey: "synthetic-test-key")
        let input = try SentenceRequest(target: "负责", left: "I am ", right: " this project.")
        let request = try provider.makeRequest(input)
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/chat/completions")
        XCTAssertEqual(request.timeoutInterval, 15)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "deepseek-flash")
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertEqual(body["thinking"] as? [String: String], ["type": "disabled"])
        XCTAssertEqual(body["response_format"] as? [String: String], ["type": "json_object"])
        XCTAssertEqual(body["max_tokens"] as? Int, 640)
        XCTAssertNil(body["tools"])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(messages[1]["content"]!.utf8)) as? [String: String])
        XCTAssertEqual(Set(payload.keys), ["target", "left", "right", "intent_hint"])
        XCTAssertEqual(payload["target"], "负责")
        XCTAssertFalse(String(decoding: request.httpBody!, as: UTF8.self).contains("synthetic-test-key"))
        XCTAssertTrue(messages[0]["content"]!.contains("voice and agency"))
        XCTAssertTrue(messages[0]["content"]!.contains("necessary English changes"))
        XCTAssertTrue(messages[0]["content"]!.contains("Do not automatically complete"))
        XCTAssertTrue(messages[0]["content"]!.contains("Learning explanations are requested separately"))
    }

    func testSuggestUnchangedAndClarifyStatuses() async throws {
        let input = try SentenceRequest(target: "I very like 这个方案.")
        let result = try await provider(#"{"status":"suggest","replacement":"I really like this approach.","message":""}"#).advice(input)
        XCTAssertEqual(result.replacement, "I really like this approach.")
        for status in ["unchanged", "clarify", "unsupported"] {
            let message = status == "unchanged" ? "" : "请确认本句含义。"
            let content = String(decoding: try JSONSerialization.data(withJSONObject:
                ["status": status, "replacement": "", "message": message]), as: UTF8.self)
            let advice = try await provider(content).advice(input)
            XCTAssertEqual(advice.status.rawValue, status)
        }
    }

    func testInvalidShapesFailClosed() async throws {
        let input = try SentenceRequest(target: "This works 轻载条件下.")
        for content in ["{}", "```json {} ```",
            #"{"status":"unknown","replacement":"English","message":""}"#,
            #"{"status":"suggest","replacement":"English","message":"","range":0}"#,
            #"{"status":"unchanged","replacement":"English","message":""}"#,
            #"{"status":"clarify","replacement":"","message":""}"#,
            #"{"status":"suggest","replacement":"","message":""}"#] {
            do { _ = try await provider(content).advice(input); XCTFail("Expected rejection") }
            catch { XCTAssertEqual(error as? CoachingProviderError, .invalidResponse) }
        }
    }

    func testProtectedNumbersTermsAndEnglishModality() throws {
        let input = try SentenceRequest(target: "At 0.5 A, ZVS may fail 轻载条件下.")
        XCTAssertNoThrow(try SentenceAdvice(status: .suggest,
            replacement: "At 0.5 A, ZVS may fail under light-load conditions.").validate(for: input))
        for replacement in ["At 0.6 A, ZVS may fail under light-load conditions.",
                            "At 0.5 V, ZVS may fail under light-load conditions.",
                            "At 0.5 A, PWM may fail under light-load conditions.",
                            "At 0.5 A, ZVS will fail under light-load conditions."] {
            XCTAssertThrowsError(try SentenceAdvice(status: .suggest, replacement: replacement).validate(for: input))
        }
        let negative = try SentenceRequest(target: "This may not work.")
        XCTAssertThrowsError(try SentenceAdvice(status: .suggest, replacement: "This may work.").validate(for: negative))
        let chinese = try SentenceRequest(target: "可能降低损耗。")
        XCTAssertNoThrow(try SentenceAdvice(status: .suggest, replacement: "It may reduce losses.").validate(for: chinese))
        XCTAssertThrowsError(try SentenceAdvice(status: .suggest, replacement: "It will reduce losses.").validate(for: chinese))
    }

    func testSelectedPhraseCannotRepeatReadOnlyContext() throws {
        let input = try SentenceRequest(target: "负责", left: "I am ", right: " this project.")
        XCTAssertThrowsError(try SentenceAdvice(status: .suggest,
            replacement: "I am responsible for this project.").validate(for: input))
        XCTAssertNoThrow(try SentenceAdvice(status: .suggest, replacement: "responsible for").validate(for: input))
    }

    func testLiteralQuotesAndResponseSizeAreChecked() throws {
        let input = try SentenceRequest(target: "The label reads “轻载条件下”.")
        XCTAssertThrowsError(try SentenceAdvice(status: .suggest,
            replacement: "The label reads under light-load conditions.").validate(for: input))
        for replacement in ["English\ntext", "English\ttext", "English\u{200B}text", String(repeating: "a", count: 901)] {
            XCTAssertThrowsError(try SentenceAdvice(status: .suggest, replacement: replacement).validate(for: input))
        }
        XCTAssertThrowsError(try SentenceAdvice(status: .clarify,
            message: String(repeating: "字", count: 161)).validate(for: input))
    }

    func testTruncationHTTPFailureAndCancellation() async throws {
        let input = try SentenceRequest(target: "This works 轻载条件下.")
        do { _ = try await provider("", finish: "length").advice(input); XCTFail("Expected truncation") }
        catch { XCTAssertEqual(error as? CoachingProviderError, .incompleteResponse) }
        do { _ = try await provider("private body", status: 429).advice(input); XCTFail("Expected rate limit") }
        catch { XCTAssertEqual(error as? CoachingProviderError, .rateLimited) }
        let task = Task { try await DemoSentenceProvider().advice(input) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testCredentialsAndUnsupportedOutputFormatRejected() throws {
        let input = try SentenceRequest(target: "This works 轻载条件下.")
        for key in ["", "key\nheader"] {
            XCTAssertThrowsError(try DeepSeekSentenceProvider(apiKey: key).makeRequest(input))
        }
        XCTAssertThrowsError(try DeepSeekSentenceProvider(configuration: ProviderConfiguration(
            baseURL: "https://api.deepseek.com", model: "deepseek-flash", outputFormat: .jsonSchema), apiKey: "test").makeRequest(input))
    }
}
