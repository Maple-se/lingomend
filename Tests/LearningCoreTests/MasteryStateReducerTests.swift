import LearningCore
import XCTest

final class MasteryStateReducerTests: XCTestCase {
    func testAssistedUseDoesNotCountAsIndependentLearning() {
        let expressionID = UUID()
        let evidence = UsageEvidence(
            expressionID: expressionID,
            type: .assisted,
            matchedText: "under light-load conditions",
            confidence: 1
        )

        XCTAssertEqual(MasteryStateReducer().state(for: [evidence]), .new)
    }

    func testIndependentUseAcrossTwoDaysBecomesFamiliar() {
        let expressionID = UUID()
        let day: TimeInterval = 86_400
        let evidence = [
            UsageEvidence(
                expressionID: expressionID,
                type: .independent,
                matchedText: "under light-load conditions",
                confidence: 1,
                occurredAt: Date(timeIntervalSince1970: day)
            ),
            UsageEvidence(
                expressionID: expressionID,
                type: .independent,
                matchedText: "under light-load conditions",
                confidence: 1,
                occurredAt: Date(timeIntervalSince1970: day * 2)
            )
        ]

        XCTAssertEqual(MasteryStateReducer().state(for: evidence), .familiar)
    }
}

