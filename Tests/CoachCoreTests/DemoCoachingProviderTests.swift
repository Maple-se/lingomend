import CoachCore
import XCTest

final class DemoCoachingProviderTests: XCTestCase {
    func testReplacesOnlyKnownPlaceholder() async throws {
        let response = try await DemoCoachingProvider().suggest(
            CoachRequest(sourceText: "This works 轻载条件下, and the rest stays.")
        )

        XCTAssertEqual(
            response.naturalText,
            "This works under light-load conditions, and the rest stays."
        )
        XCTAssertEqual(response.learningPoints.count, 1)
        XCTAssertEqual(response.learningPoints.first?.target, "under light-load conditions")
    }

    func testUnknownTextIsUnchangedAndWarned() async throws {
        let response = try await DemoCoachingProvider().suggest(
            CoachRequest(sourceText: "Already correct English.")
        )

        XCTAssertEqual(response.naturalText, "Already correct English.")
        XCTAssertTrue(response.learningPoints.isEmpty)
        XCTAssertFalse(response.warnings.isEmpty)
    }
}
