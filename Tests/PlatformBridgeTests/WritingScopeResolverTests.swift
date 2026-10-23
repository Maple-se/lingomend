import Foundation
import PlatformBridge
import XCTest

final class WritingScopeResolverTests: XCTestCase {
    private func snapshot(_ text: String, _ range: NSRange) -> TextSnapshot {
        TextSnapshot(applicationIdentifier: "synthetic.editor", focusedElementIdentifier: "field",
            text: text, selectedRange: range, revisionToken: "1")
    }
    func testCaretStaysInItsSentence() throws {
        let text = "Keep this. I very like 这个方案. Leave that."
        let original = snapshot(text, NSRange(location: (text as NSString).range(of: "very").location, length: 0))
        let scope = try WritingScopeResolver().resolve(original)
        XCTAssertEqual(scope.context.text, "I very like 这个方案.")
        XCTAssertFalse(scope.isPassage)
    }
    func testExplicitParagraphIsOnlyAuthorizedEditBoundary() throws {
        let selected = "I very like 这个方案.\nThis works 轻载条件下."
        let text = "Before stays.\n" + selected + "\nAfter stays."
        let original = snapshot(text, (text as NSString).range(of: selected))
        let scope = try WritingScopeResolver().resolve(original)
        XCTAssertTrue(scope.isPassage)
        XCTAssertEqual(scope.context.text, selected)
        let plan = try SentenceEditPlan(original: original, scope: scope,
            replacement: "I really like this approach.\nThis works under light-load conditions.")
        XCTAssertEqual(plan.expectedText, "Before stays.\nI really like this approach.\nThis works under light-load conditions.\nAfter stays.")
        XCTAssertTrue(plan.range.location >= original.selectedRange.location)
        XCTAssertTrue(NSMaxRange(plan.range) <= NSMaxRange(original.selectedRange))
    }
    func testLongSelectionBoundedAndCaretDoesNotEscalate() throws {
        let text = String(repeating: "x", count: 700)
        let selected = snapshot(text, NSRange(location: 0, length: text.utf16.count))
        XCTAssertTrue(try WritingScopeResolver().resolve(selected).isPassage)
        XCTAssertThrowsError(try WritingScopeResolver().resolve(snapshot(text, NSRange(location: 10, length: 0))))
        XCTAssertThrowsError(try WritingScopeResolver().resolve(snapshot(text, NSRange(location: 10, length: 5))))
        let oversized = String(repeating: "x", count: 1_201)
        XCTAssertThrowsError(try WritingScopeResolver().resolve(snapshot(oversized, NSRange(location: 0, length: 1_201))))
    }
    func testNonSelectableControlCanUseAnExistingExplicitSelection() throws {
        let text = "I very like 这个方案."
        let original = snapshot(text, NSRange(location: 0, length: text.utf16.count))
        let scope = try WritingScopeResolver().resolve(original)
        let edit = try SentenceEditPlan(original: original, scope: scope,
            replacement: "I really like this approach.", preserveExplicitSelection: true)
        XCTAssertEqual(edit.range, original.selectedRange)
        XCTAssertEqual(edit.insertedText, edit.replacement)
        XCTAssertNil(edit.refusal(current: original))
    }
    func testReadOnlyAndDisabledFieldsCannotAccept() {
        let selection = NSRange(location: 0, length: 5)
        let readOnly = EditorCapabilities(role: "AXTextArea", enabled: true, explicitlyEditable: false,
            valueSettable: false, selectedTextSettable: false, rangeSettable: true)
        XCTAssertFalse(readOnly.canAccept(selection: selection))
        let disabled = EditorCapabilities(role: "AXTextField", enabled: false, explicitlyEditable: true,
            valueSettable: true, selectedTextSettable: true, rangeSettable: true)
        XCTAssertFalse(disabled.canAccept(selection: selection))
        let label = EditorCapabilities(role: "AXStaticText", enabled: true, explicitlyEditable: nil,
            valueSettable: false, selectedTextSettable: false, rangeSettable: true)
        XCTAssertFalse(label.canAccept(selection: selection))
        let normal = EditorCapabilities(role: "AXTextArea", enabled: true, explicitlyEditable: nil,
            valueSettable: true, selectedTextSettable: false, rangeSettable: true)
        XCTAssertTrue(normal.canAccept(selection: NSRange(location: 3, length: 0)))
        let existingSelection = EditorCapabilities(role: "AXTextArea", enabled: true, explicitlyEditable: true,
            valueSettable: false, selectedTextSettable: true, rangeSettable: false)
        XCTAssertTrue(existingSelection.canAccept(selection: selection))
        XCTAssertFalse(existingSelection.canAccept(selection: NSRange(location: 3, length: 0)))
    }
}
