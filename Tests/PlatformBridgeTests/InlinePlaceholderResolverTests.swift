import Foundation
import PlatformBridge
import XCTest

final class InlinePlaceholderResolverTests: XCTestCase {
    private func snapshot(_ text: String, caret: Int? = nil, selection: NSRange? = nil) -> TextSnapshot {
        TextSnapshot(applicationIdentifier: "test", focusedElementIdentifier: "field", text: text,
            selectedRange: selection ?? NSRange(location: caret ?? text.utf16.count, length: 0), revisionToken: "r")
    }
    func testMixedParagraphDetectsPlaceholderWithoutSelection() throws {
        let value = "This works 轻载条件下."
        let result = try XCTUnwrap(InlinePlaceholderResolver().resolve(snapshot(value)))
        XCTAssertEqual(result.text, "轻载条件下")
        XCTAssertEqual((value as NSString).substring(with: result.range), result.text)
    }
    func testDoesNotReadAdjacentParagraph() throws {
        let text = "Private unrelated paragraph.\nThis works 轻载条件下."
        let result = try XCTUnwrap(InlinePlaceholderResolver().resolve(snapshot(text)))
        XCTAssertEqual(result.context.text, "This works 轻载条件下.")
        XCTAssertGreaterThan(result.range.location, 20)
    }
    func testPureChineseFieldDoesNotActAsTranslator() {
        XCTAssertNil(InlinePlaceholderResolver().resolve(snapshot("这是一段中文")))
    }
    func testExplicitChineseSelectionIsEligible() {
        let text = "This works 轻载条件下."
        let range = (text as NSString).range(of: "轻载条件下")
        XCTAssertEqual(InlinePlaceholderResolver().resolve(snapshot(text, selection: range))?.text, "轻载条件下")
    }
    func testUnfinishedLatinCompositionAfterPlaceholderDoesNotTrigger() {
        XCTAssertNil(InlinePlaceholderResolver().resolve(snapshot("This works 轻载条件下 shi")))
    }
    func testNearestChineseRunWinsAndEmojiOffsetsAreUTF16() throws {
        let text = "🙂 We use 方法A 轻载条件下."
        let result = try XCTUnwrap(InlinePlaceholderResolver().resolve(snapshot(text)))
        XCTAssertEqual(result.text, "轻载条件下")
        XCTAssertEqual((text as NSString).substring(with: result.range), result.text)
    }
    func testDistantCaretAndLongParagraphDoNotTrigger() {
        XCTAssertNil(InlinePlaceholderResolver().resolve(snapshot("This works 轻载条件下" + String(repeating: " ", count: 25))))
        XCTAssertNil(InlinePlaceholderResolver().resolve(snapshot(String(repeating: "a", count: 1_001) + "轻载条件下")))
        XCTAssertNil(InlinePlaceholderResolver().resolve(snapshot("English " + String(repeating: "中", count: 41))))
    }
    func testEnglishOnlyAndCaretBeforePlaceholderDoNotTrigger() {
        XCTAssertNil(InlinePlaceholderResolver().resolve(snapshot("This works.")))
        XCTAssertNil(InlinePlaceholderResolver().resolve(snapshot("This works 轻载条件下.", caret: 2)))
    }
}
