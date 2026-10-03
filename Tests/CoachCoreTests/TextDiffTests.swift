import CoachCore
import XCTest

final class TextDiffTests: XCTestCase {
    func testReconstructsBothInputsIncludingUnicodeAndRepeatedWords() {
        for (source, target) in [("This works 轻载条件下.", "This works under light-load conditions."),
                                 ("a a a", "a b a"), ("🙂 x", "🙂 xy"), ("", "word"), ("word", ""),
                                 (String(repeating: "a ", count: 2_001), String(repeating: "b ", count: 2_001))] {
            let segments = TextDiff().segments(from: source, to: target)
            XCTAssertEqual(segments.filter { $0.kind != .inserted }.map(\.text).joined(), source)
            XCTAssertEqual(segments.filter { $0.kind != .removed }.map(\.text).joined(), target)
        }
    }
    func testIdenticalTextHasNoChanges() {
        XCTAssertEqual(TextDiff().changedFraction(from: "Same.", to: "Same."), 0)
        XCTAssertLessThanOrEqual(TextDiff().changedFraction(from: "a", to: "bb"), 1)
    }
}
