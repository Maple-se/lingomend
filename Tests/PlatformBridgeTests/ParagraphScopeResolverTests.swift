import Foundation
import PlatformBridge
import XCTest

final class ParagraphScopeResolverTests: XCTestCase {
    func testExplicitSelectionWins() {
        let text = "First paragraph.\nSecond paragraph."
        let snapshot = TextSnapshot(
            applicationIdentifier: "test",
            text: text,
            selectedRange: NSRange(location: 17, length: 6),
            revisionToken: "1"
        )

        let scope = ParagraphScopeResolver().resolve(snapshot: snapshot)

        XCTAssertEqual(scope?.text, "Second")
        XCTAssertEqual(scope?.kind, .explicitSelection)
    }

    func testShortFieldUsesWholeTextWithoutSelection() {
        let text = "I think 这个方法 is better."
        let snapshot = TextSnapshot(
            applicationIdentifier: "test",
            text: text,
            selectedRange: NSRange(location: (text as NSString).length, length: 0),
            revisionToken: "1"
        )

        let scope = ParagraphScopeResolver().resolve(snapshot: snapshot)

        XCTAssertEqual(scope?.text, text)
        XCTAssertEqual(scope?.kind, .wholeShortField)
    }

    func testLongFieldUsesParagraphAtCaret() {
        let first = String(repeating: "Earlier context. ", count: 24)
        let target = "  I think 这个方法 is better under light load.  "
        let text = "\(first)\n\(target)\nLater context."
        let location = ("\(first)\n  I think" as NSString).length
        let snapshot = TextSnapshot(
            applicationIdentifier: "test",
            text: text,
            selectedRange: NSRange(location: location, length: 0),
            revisionToken: "1"
        )

        let scope = ParagraphScopeResolver().resolve(snapshot: snapshot)

        XCTAssertEqual(scope?.text, target.trimmingCharacters(in: .whitespaces))
        XCTAssertEqual(scope?.kind, .paragraphAtCaret)
    }
}

