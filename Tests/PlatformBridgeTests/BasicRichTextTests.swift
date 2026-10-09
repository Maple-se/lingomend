import AppKit
@preconcurrency import ApplicationServices
import PlatformBridge
import XCTest

final class BasicRichTextTests: XCTestCase {
  @MainActor func testNeutralAXStylesAndMetadataDoNotRejectPlainText() async throws {
    let superscript = NSAttributedString.Key(kAXSuperscriptTextAttribute.takeUnretainedValue() as String)
    let source = NSMutableAttributedString(string: "Synthetic", attributes: [
      .font: NSFont.systemFont(ofSize: 12), superscript: 0,
      NSAttributedString.Key(kAXShadowTextAttribute.takeUnretainedValue() as String): false,
      NSAttributedString.Key(kAXNaturalLanguageTextAttribute.takeUnretainedValue() as String): "en",
    ])
    XCTAssertEqual(try BasicRichText.normalize(source).string, source.string)
    source.addAttribute(superscript, value: 1, range: NSRange(location: 0, length: source.length))
    XCTAssertThrowsError(try BasicRichText.normalize(source))
  }
  @MainActor func testAXFontColorAndUnderlineNormalize() async throws {
    let font = NSFont.boldSystemFont(ofSize: 18)
    let input = NSAttributedString(
      string: "Synthetic",
      attributes: [
        NSAttributedString.Key(kAXFontTextAttribute.takeUnretainedValue() as String): [
          kAXFontNameKey.takeUnretainedValue() as String: font.fontName,
          kAXFontSizeKey.takeUnretainedValue() as String: NSNumber(value: 18),
        ],
        NSAttributedString.Key(kAXForegroundColorTextAttribute.takeUnretainedValue() as String):
          NSColor.red.cgColor,
        NSAttributedString.Key(kAXUnderlineTextAttribute.takeUnretainedValue() as String): NSNumber(
          value: 1),
      ])
    let result = try BasicRichText.normalize(input)
    XCTAssertEqual((result.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 18)
    XCTAssertEqual(result.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? NSNumber, 1)
    XCTAssertNotNil(result.attribute(.foregroundColor, at: 0, effectiveRange: nil))
  }
  @MainActor func testUnchangedRunsAndInsertedPhraseKeepBasicStyleThroughRTF() async throws {
    let source = NSMutableAttributedString(
      string: "We need 降低损耗 without 增加成本.", attributes: [.font: NSFont.systemFont(ofSize: 15)])
    source.addAttributes(
      [.font: NSFont.boldSystemFont(ofSize: 18), .foregroundColor: NSColor.red],
      range: (source.string as NSString).range(of: "降低损耗"))
    source.addAttributes(
      [.underlineStyle: 1], range: (source.string as NSString).range(of: "without"))
    source.addAttributes(
      [
        .font: NSFontManager.shared.convert(
          NSFont.systemFont(ofSize: 15), toHaveTrait: .italicFontMask)
      ],
      range: (source.string as NSString).range(of: "增加成本"))
    let result = try BasicRichText.replacement(
      source: source, text: "We need reduce losses without increasing costs.")
    let data = try result.data(
      from: NSRange(location: 0, length: result.length),
      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    let roundTrip = try NSAttributedString(
      data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
      documentAttributes: nil)
    let bold = (roundTrip.string as NSString).range(of: "reduce").location
    let unchanged = (roundTrip.string as NSString).range(of: "without").location
    XCTAssertEqual(
      (roundTrip.attribute(.font, at: bold, effectiveRange: nil) as? NSFont)?.pointSize, 18)
    XCTAssertEqual(
      roundTrip.attribute(.underlineStyle, at: unchanged, effectiveRange: nil) as? NSNumber, 1)
    XCTAssertEqual(roundTrip.string, result.string)
  }
  @MainActor func testInsertDeleteEmojiAndCombiningCharacters() async throws {
    for (before, after) in [
      ("I like it.", "I really like it."), ("I really like it.", "I like it."),
      ("🙂 Café 轻载条件下.", "🙂 Café works well."), ("中文。", "English."),
    ] {
      let source = NSAttributedString(
        string: before, attributes: [.font: NSFont.systemFont(ofSize: 12)])
      XCTAssertEqual(try BasicRichText.replacement(source: source, text: after).string, after)
    }
  }
  @MainActor func testMissingFontAttachmentsAndUnknownStylesRefuse() async throws {
    XCTAssertThrowsError(try BasicRichText.normalize(NSAttributedString(string: "Synthetic")))
    for key in [
      NSAttributedString.Key.attachment, .link, .superscript,
      NSAttributedString.Key("AXUnknownLayout"),
    ] {
      XCTAssertThrowsError(
        try BasicRichText.normalize(
          NSAttributedString(
            string: "Synthetic",
            attributes: [
              .font: NSFont.systemFont(ofSize: 12), key: "unsupported",
            ])))
    }
  }
}
