import Foundation
import PlatformBridge
import XCTest

final class SentenceEditPlanTests: XCTestCase {
  private func snapshot(
    _ text: String, selection: NSRange? = nil, app: String = "com.apple.TextEdit"
  ) -> TextSnapshot {
    TextSnapshot(
      applicationIdentifier: app, focusedElementIdentifier: "synthetic-field", text: text,
      selectedRange: selection ?? NSRange(location: text.utf16.count, length: 0),
      revisionToken: "v1")
  }
  private func plan(_ text: String, replacement: String, selection: NSRange? = nil) throws
    -> SentenceEditPlan
  {
    let original = snapshot(text, selection: selection)
    return try SentenceEditPlan(
      original: original, scope: SentenceScopeResolver().resolve(original), replacement: replacement
    )
  }
  func testMinimalGapAndOutsideSentenceAreUntouched() throws {
    let text = "First stays. This works 轻载条件下. Last stays."
    let position = (text as NSString).range(of: "works").location
    let edit = try plan(
      text, replacement: "This works under light-load conditions.",
      selection: NSRange(location: position, length: 0))
    XCTAssertEqual(edit.range, (text as NSString).range(of: "轻载条件下"))
    XCTAssertEqual(edit.insertedText, "under light-load conditions")
    XCTAssertEqual(
      edit.expectedText, "First stays. This works under light-load conditions. Last stays.")
    XCTAssertEqual(
      edit.caretAfter.location, "First stays. This works under light-load conditions.".utf16.count)
  }
  func testTwoGapsRemainOneBoundedEdit() throws {
    let edit = try plan(
      "We need 降低损耗 without 增加成本.", replacement: "We need reduce losses without increasing costs.")
    XCTAssertEqual(edit.source, "降低损耗 without 增加成本")
    XCTAssertEqual(edit.insertedText, "reduce losses without increasing costs")
    XCTAssertEqual(edit.expectedText, "We need reduce losses without increasing costs.")
  }
  func testSelectionCannotExpandToNeighbours() throws {
    let text = "I am 负责 this project."
    let selected = ("I am 负责 this project." as NSString).range(of: "负责")
    let edit = try plan(text, replacement: "responsible for", selection: selected)
    XCTAssertEqual(edit.range, selected)
    XCTAssertEqual(edit.expectedText, "I am responsible for this project.")
    XCTAssertEqual(edit.caretAfter.location, "I am responsible for".utf16.count)
  }
  func testPureInsertionHasZeroLengthSource() throws {
    let edit = try plan("I like it.", replacement: "I really like it.")
    XCTAssertEqual(edit.range.length, 0)
    XCTAssertEqual(edit.source, "")
    XCTAssertEqual(edit.expectedText, "I really like it.")
  }
  func testPureDeletionIncludesOneUnchangedCharacterForNativePaste() throws {
    let edit = try plan("I really like it.", replacement: "I like it.")
    XCTAssertFalse(edit.insertedText.isEmpty)
    XCTAssertEqual(edit.expectedText, "I like it.")
    XCTAssertLessThan(edit.range.length, edit.scope.target.range.length)
  }
  func testUnicodeGraphemesAndRepeatedPhrasesUseOriginalCoordinates() throws {
    let text = "🙂 This works 轻载条件下. This works 轻载条件下."
    let edit = try plan(
      text, replacement: "🙂 This works under light-load conditions.",
      selection: NSRange(location: 3, length: 0))
    XCTAssertEqual(edit.expectedText, "🙂 This works under light-load conditions. This works 轻载条件下.")
    XCTAssertNotNil(Range(edit.range, in: text))
    let composed = try plan("Café works 轻载条件下.", replacement: "Café works well.")
    XCTAssertNotNil(Range(composed.range, in: composed.original.text))
  }
  func testSameSnapshotAllowedAndEachStaleBoundaryRefused() throws {
    let edit = try plan("This works 轻载条件下.", replacement: "This works well.")
    XCTAssertNil(edit.refusal(current: edit.original))
    for (app, field, text, selection, revision, expected) in [
      (
        "other.app", "synthetic-field", edit.original.text, edit.original.selectedRange, "v1",
        ReplacementRefusal.focusChanged
      ),
      (
        "com.apple.TextEdit", "other-field", edit.original.text, edit.original.selectedRange, "v1",
        .focusChanged
      ),
      (
        "com.apple.TextEdit", "synthetic-field", "Edited.", edit.original.selectedRange, "v1",
        .sourceChanged
      ),
      (
        "com.apple.TextEdit", "synthetic-field", edit.original.text,
        NSRange(location: 0, length: 0), "v1", .selectionChanged
      ),
      (
        "com.apple.TextEdit", "synthetic-field", edit.original.text, edit.original.selectedRange,
        "v2", .sourceChanged
      ),
    ] {
      XCTAssertEqual(
        edit.refusal(
          current: TextSnapshot(
            applicationIdentifier: app, focusedElementIdentifier: field,
            text: text, selectedRange: selection, revisionToken: revision)), expected)
    }
  }
  func testUnchangedInvalidAndUnsupportedPlansRejected() throws {
    let original = snapshot("This works 轻载条件下.")
    let scope = try SentenceScopeResolver().resolve(original)
    for replacement in ["", "Changed.\nAnother.", String(repeating: "x", count: 901)] {
      XCTAssertThrowsError(
        try SentenceEditPlan(original: original, scope: scope, replacement: replacement))
    }
    XCTAssertThrowsError(
      try SentenceEditPlan(original: original, scope: scope, replacement: scope.target.text))
    let other = snapshot(original.text, app: "com.apple.Safari")
    XCTAssertThrowsError(
      try SentenceEditPlan(original: other, scope: scope, replacement: "This works well."))
    let forged = try SentenceScopeResolver().resolve(
      snapshot(original.text, selection: NSRange(location: 0, length: 4)))
    XCTAssertThrowsError(
      try SentenceEditPlan(original: original, scope: forged, replacement: "That"))
  }
}
