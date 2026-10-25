import Foundation
import DiagnosticsCore
@testable import PlatformBridge
import XCTest

final class EditorCaptureRegressionTests: XCTestCase {
    func testEmptyProxyUsesBoundedTextInterface() throws {
        let actual = "I like这个方案. 🧭"
        var requested: NSRange?
        let result = try AXTextContent.resolve(value: "", count: actual.utf16.count) { range in
            requested = range; return actual
        }
        XCTAssertEqual(result, actual)
        XCTAssertEqual(requested, NSRange(location: 0, length: actual.utf16.count))
        XCTAssertEqual(try AXTextContent.resolve(value: "\n", count: actual.utf16.count) { _ in actual }, actual)
    }
    func testDirectTextDoesNotCallFallbackAndMissingValueCanUseAttributedText() throws {
        XCTAssertEqual(try AXTextContent.resolve(value: "Valid.", count: 9) { _ in
            XCTFail("Do not read a second surface when direct text exists"); return nil
        }, "Valid.")
        XCTAssertEqual(try AXTextContent.resolve(value: nil, count: 5) { _ in "Word." }, "Word.")
    }
    func testMismatchedRangeAndOversizedDocumentDoNotCreateSnapshot() throws {
        XCTAssertNil(try AXTextContent.resolve(value: nil, count: 12) { _ in "short" })
        XCTAssertThrowsError(try AXTextContent.resolve(value: nil, count: 65_537) { _ in
            XCTFail("Oversized text must not be requested"); return nil
        })
        XCTAssertNil(try AXTextContent.resolve(value: nil, count: nil) { _ in
            XCTFail("Never invent document coordinates"); return nil
        })
    }
    func testAmbiguousOrUnrelatedFieldsCannotBeChosenByRoleScore() {
        XCTAssertNil(EditorCandidateSelection.uniqueFocusedDescendant([]))
        XCTAssertNil(EditorCandidateSelection.uniqueFocusedDescendant([false, false]))
        XCTAssertNil(EditorCandidateSelection.uniqueFocusedDescendant([true, true]))
        XCTAssertEqual(EditorCandidateSelection.uniqueFocusedDescendant([false, true, false]), 1)
    }
    func testContentSelectionFocusAndUnchangedAreDistinct() {
        func snapshot(text: String = "A sentence.", field: String = "focused", location: Int = 2) -> TextSnapshot {
            TextSnapshot(applicationIdentifier: "synthetic.app", focusedElementIdentifier: field,
                text: text, selectedRange: NSRange(location: location, length: 0), revisionToken: text)
        }
        let original = snapshot()
        XCTAssertNil(snapshot().changeReason(comparedTo: original))
        XCTAssertEqual(snapshot(text: "Changed.").changeReason(comparedTo: original), .sourceChanged)
        XCTAssertEqual(snapshot(location: 3).changeReason(comparedTo: original), .selectionChanged)
        XCTAssertEqual(snapshot(field: "another-input").changeReason(comparedTo: original), .focusChanged)
    }
}
