import CoachCore
import Foundation
import XCTest

final class SelectedPassageTests: XCTestCase {
    func testMultiSentenceDemoAndExplicitRequestBudget() async throws {
        let input = try SentenceRequest(target: "I very like 这个方案.\nThis works 轻载条件下.", extent: .selectedPassage)
        let advice = try await DemoSentenceProvider().advice(input)
        XCTAssertEqual(advice.replacement, "I really like this approach.\nThis works under light-load conditions.")
        let request = try DeepSeekSentenceProvider(apiKey: "synthetic").makeRequest(input)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["max_tokens"] as? Int, 1_400)
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertTrue(messages[0]["content"]?.contains("extent=selected_passage") == true)
    }
    func testPassageKeepsTechnicalFactsNegationAndMeaningfulBounds() throws {
        let input = try SentenceRequest(target: "At 0.5 A, ZVS may not work.\nWe need 降低损耗.", extent: .selectedPassage)
        try SentenceAdvice(status: .suggest, replacement: "At 0.5 A, ZVS may not work.\nWe need to reduce losses.").validate(for: input)
        for replacement in ["At 5 A, ZVS may not work.\nWe need to reduce losses.",
                            "At 0.5 A, ZVS will work.\nWe need to reduce losses.",
                            "At 0.5 A, ZVS may not work. We need to reduce losses.",
                            String(repeating: "English ", count: 230)] {
            XCTAssertThrowsError(try SentenceAdvice(status: .suggest, replacement: replacement).validate(for: input))
        }
        XCTAssertThrowsError(try SentenceRequest(target: String(repeating: "x", count: 1_201), extent: .selectedPassage))
        XCTAssertThrowsError(try SentenceRequest(target: "Text\tmore", extent: .selectedPassage))
        XCTAssertThrowsError(try SentenceRequest(target: "Selected.", left: "Outside ", extent: .selectedPassage))
        XCTAssertThrowsError(try SentenceRequest(target: "One.\nTwo."))
    }
}
