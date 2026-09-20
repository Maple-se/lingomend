import CoachCore
import XCTest

final class CoachResponseValidatorTests: XCTestCase {
    func testAcceptsSmallStructuredResponse() throws {
        let response = CoachResponse(
            naturalText: "This method is efficient under light-load conditions.",
            meaningPreserved: true,
            learningPoints: [
                LearningPoint(
                    source: "轻载条件下",
                    target: "under light-load conditions",
                    explanation: "A common technical collocation.",
                    category: .collocation
                )
            ]
        )

        XCTAssertNoThrow(try CoachResponseValidator().validate(response))
    }

    func testRejectsMeaningChange() {
        let response = CoachResponse(
            naturalText: "A different claim.",
            meaningPreserved: false
        )

        XCTAssertThrowsError(try CoachResponseValidator().validate(response)) { error in
            XCTAssertEqual(error as? CoachResponseValidationError, .meaningNotPreserved)
        }
    }
}

