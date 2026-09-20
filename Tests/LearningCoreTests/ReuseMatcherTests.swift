import CoachCore
import LearningCore
import XCTest

final class ReuseMatcherTests: XCTestCase {
    func testFindsCanonicalExpressionInOriginalDraft() {
        let expression = Expression(
            sourcePhrase: "轻载条件下",
            canonicalTarget: "under light-load conditions",
            targetPatterns: ["at light load"],
            category: .collocation
        )

        let match = ReuseMatcher().match(
            expression: expression,
            in: "The converter remains efficient under light-load conditions."
        )

        XCTAssertEqual(match?.expressionID, expression.id)
        XCTAssertEqual(match?.confidence, 1)
        XCTAssertEqual(match?.isCanonical, true)
    }

    func testFindsAcceptedVariant() {
        let expression = Expression(
            sourcePhrase: "轻载条件下",
            canonicalTarget: "under light-load conditions",
            targetPatterns: ["at light load"],
            category: .collocation
        )

        let match = ReuseMatcher().match(
            expression: expression,
            in: "The loss becomes significant at light load."
        )

        XCTAssertEqual(match?.confidence, 0.85)
        XCTAssertEqual(match?.isCanonical, false)
    }
}

