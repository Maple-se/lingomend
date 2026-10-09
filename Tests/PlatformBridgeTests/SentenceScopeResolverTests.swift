import Foundation
import PlatformBridge
import XCTest

final class SentenceScopeResolverTests: XCTestCase {
    private func snapshot(_ text: String, range: NSRange? = nil) -> TextSnapshot {
        TextSnapshot(applicationIdentifier: "com.apple.TextEdit", focusedElementIdentifier: "synthetic-editor",
            text: text, selectedRange: range ?? NSRange(location: (text as NSString).length, length: 0), revisionToken: "test")
    }

    func testCaretUsesOneSentenceNotWholeShortField() throws {
        let scope = try SentenceScopeResolver().resolve(snapshot("First stays. This works 轻载条件下."))
        XCTAssertEqual(scope.context.text, "This works 轻载条件下.")
        XCTAssertEqual(scope.target, scope.context)
        XCTAssertEqual(scope.context.kind, .sentenceAtCaret)
    }

    func testCaretBeforeGapStillGetsRightSideOfSentence() throws {
        let text = "First stays. This works 轻载条件下. Last stays."
        let position = (text as NSString).range(of: "works").location
        let scope = try SentenceScopeResolver().resolve(snapshot(text, range: NSRange(location: position, length: 0)))
        XCTAssertEqual(scope.context.text, "This works 轻载条件下.")
    }

    func testSelectedGapUsesReadOnlyFullSentenceContext() throws {
        let text = "First stays. I am 负责 this project."
        let range = (text as NSString).range(of: "负责")
        let scope = try SentenceScopeResolver().resolve(snapshot(text, range: range))
        XCTAssertEqual(scope.context.text, "I am 负责 this project.")
        XCTAssertEqual(scope.target.text, "负责"); XCTAssertEqual(scope.target.range, range)
    }

    func testSelectedSentenceAndMultiSentenceSelection() throws {
        let text = "One stays. Two stays."
        let scope = try SentenceScopeResolver().resolve(snapshot(text, range: (text as NSString).range(of: "Two stays.")))
        XCTAssertEqual(scope.target.text, "Two stays.")
        XCTAssertThrowsError(try SentenceScopeResolver().resolve(snapshot(text, range: NSRange(location: 0, length: text.utf16.count)))) {
            XCTAssertEqual($0 as? SentenceScopeError, .multipleSentences)
        }
    }

    func testAbbreviationsInitialsAndDecimalsStayTogether() throws {
        for text in ["Dr. Li checks Fig. 2 at 0.5 A 轻载条件下.", "J. Smith uses e.g. ZVS 测试.",
                     "Use example.com and name@example.com 轻载条件下."] {
            XCTAssertEqual(try SentenceScopeResolver().resolve(snapshot(text)).context.text, text)
        }
    }

    func testChinesePunctuationAndSoftWrapIndependentOfNewlines() throws {
        let text = "第一句。This works 轻载条件下！"
        XCTAssertEqual(try SentenceScopeResolver().resolve(snapshot(text)).target.text, "This works 轻载条件下！")
        let long = "This sentence has spaces and does not contain any explicit line break 轻载条件下."
        XCTAssertEqual(try SentenceScopeResolver().resolve(snapshot(long)).target.text, long)
    }

    func testQuotesAndParentheticalDecimalsDoNotSplitSentence() throws {
        for text in ["The label reads “轻载条件下。” and stays unchanged.",
                     "The label reads \"This works.\" and stays unchanged.",
                     "The label reads 'This works.' and stays unchanged.",
                     "It works (e.g. at 0.5 A) 轻载条件下."] {
            XCTAssertEqual(try SentenceScopeResolver().resolve(snapshot(text)).target.text, text)
        }
        XCTAssertEqual(try SentenceScopeResolver().resolve(snapshot("He said “Hello.” This works 轻载条件下.")).target.text,
            "This works 轻载条件下.")
    }

    func testBoundaryWhitespaceAndNewBlankParagraph() throws {
        let text = "One stays.   Two stays."
        for location in [10, 11, 12] {
            XCTAssertEqual(try SentenceScopeResolver().resolve(snapshot(text,
                range: NSRange(location: location, length: 0))).target.text, "One stays.")
        }
        XCTAssertEqual(try SentenceScopeResolver().resolve(snapshot(text,
            range: NSRange(location: 13, length: 0))).target.text, "Two stays.")
        XCTAssertThrowsError(try SentenceScopeResolver().resolve(snapshot("One stays.\n"))) {
            XCTAssertEqual($0 as? SentenceScopeError, .empty)
        }
    }

    func testListAndTitleUseOnlyCurrentLine() throws {
        let text = "Title\n- This works 轻载条件下\nOther item"
        let caret = (text as NSString).range(of: "轻载条件下").location
        XCTAssertEqual(try SentenceScopeResolver().resolve(snapshot(text,
            range: NSRange(location: caret, length: 0))).target.text, "- This works 轻载条件下")
    }

    func testUTF16RangeAfterEmojiAndCRLF() throws {
        let text = "😀 stays.\r\nThis works 轻载条件下."
        let selection = (text as NSString).range(of: "轻载条件下")
        let scope = try SentenceScopeResolver().resolve(snapshot(text, range: selection))
        XCTAssertEqual(scope.target.range, selection); XCTAssertEqual(scope.context.text, "This works 轻载条件下.")
        XCTAssertThrowsError(try SentenceScopeResolver().resolve(snapshot("😀", range: NSRange(location: 1, length: 0))))
        XCTAssertThrowsError(try SentenceScopeResolver().resolve(snapshot("e\u{301} works.",
            range: NSRange(location: 1, length: 0))))
    }

    func testEmptyInvalidAndLongInputsFailBeforeGeneration() throws {
        for text in ["", "  ", "\n  "] { XCTAssertThrowsError(try SentenceScopeResolver().resolve(snapshot(text))) }
        for range in [NSRange(location: NSNotFound, length: 0), NSRange(location: -1, length: 0),
                      NSRange(location: 100, length: 0), NSRange(location: 0, length: 99)] {
            XCTAssertThrowsError(try SentenceScopeResolver().resolve(snapshot("Test.", range: range)))
        }
        XCTAssertThrowsError(try SentenceScopeResolver().resolve(snapshot(String(repeating: "a", count: 601)))) {
            XCTAssertEqual($0 as? SentenceScopeError, .tooLong)
        }
    }
}
