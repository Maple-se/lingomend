import AppKit
@preconcurrency import ApplicationServices

public enum NativePasteError: Error, Equatable, Sendable {
  case busy
  case stale(ReplacementRefusal)
  case formatUnavailable, unsupportedFormat
  case clipboardUnavailable, clipboardChanged, modifiersHeld, selectionFailed, eventUnavailable
  case resultUnconfirmed
  case clipboardRestorationFailed(dispatched: Bool)
}

/// Converts AX's font dictionary/color attributes, not just the text, to native RTF attributes.
@MainActor
public enum BasicRichText {
  public static func normalize(_ input: NSAttributedString) throws -> NSAttributedString {
    let output = NSMutableAttributedString(string: input.string)
    var failure: NativePasteError?
    input.enumerateAttributes(in: NSRange(location: 0, length: input.length)) { attrs, range, _ in
      var native: [NSAttributedString.Key: Any] = [:]
      let axFont = NSAttributedString.Key(kAXFontTextAttribute.takeUnretainedValue() as String)
      if let font = attrs[.font] as? NSFont {
        native[.font] = font
      } else if let dictionary = attrs[axFont] as? [String: Any],
        let name = dictionary[kAXFontNameKey.takeUnretainedValue() as String] as? String,
        let size = dictionary[kAXFontSizeKey.takeUnretainedValue() as String] as? NSNumber,
        size.doubleValue.isFinite, size.doubleValue > 0,
        let font = NSFont(name: name, size: CGFloat(size.doubleValue))
      {
        native[.font] = font
      } else {
        failure = .formatUnavailable
        return
      }
      let direct: Set<NSAttributedString.Key> = [
        .font, .foregroundColor, .backgroundColor,
        .underlineStyle, .underlineColor, .strikethroughStyle, .strikethroughColor, .paragraphStyle,
      ]
      for key in direct where key != .font {
        if let value = attrs[key] { native[key] = value }
      }
      if let style = native[.paragraphStyle] as? NSParagraphStyle,
        !style.textBlocks.isEmpty || !style.textLists.isEmpty
      {
        failure = .unsupportedFormat
        return
      }
      let colors: [(CFString, NSAttributedString.Key)] = [
        (kAXForegroundColorTextAttribute.takeUnretainedValue(), .foregroundColor),
        (kAXBackgroundColorTextAttribute.takeUnretainedValue(), .backgroundColor),
        (kAXUnderlineColorTextAttribute.takeUnretainedValue(), .underlineColor),
        (kAXStrikethroughColorTextAttribute.takeUnretainedValue(), .strikethroughColor),
      ]
      for (ax, key) in colors {
        if let value = attrs[NSAttributedString.Key(ax as String)] {
          guard CFGetTypeID(value as CFTypeRef) == CGColor.typeID,
            let color = NSColor(cgColor: value as! CGColor)
          else {
            failure = .unsupportedFormat
            return
          }
          native[key] = color
        }
      }
      let styles: [(CFString, NSAttributedString.Key)] = [
        (kAXUnderlineTextAttribute.takeUnretainedValue(), .underlineStyle),
        (kAXStrikethroughTextAttribute.takeUnretainedValue(), .strikethroughStyle),
      ]
      for (ax, key) in styles {
        if let value = attrs[NSAttributedString.Key(ax as String)] as? NSNumber {
          native[key] = value
        }
      }
      // AX can explicitly report disabled advanced styles on otherwise plain text.
      let neutral: Set<NSAttributedString.Key> = [
        .superscript, NSAttributedString.Key(kAXSuperscriptTextAttribute.takeUnretainedValue() as String),
        NSAttributedString.Key(kAXShadowTextAttribute.takeUnretainedValue() as String),
      ]
      for key in neutral where attrs[key] != nil {
        guard let value = attrs[key] as? NSNumber, value.doubleValue == 0 else {
          failure = .unsupportedFormat; return
        }
      }
      let accepted = direct.union([axFont]).union(
        colors.map { NSAttributedString.Key($0.0 as String) }
      )
      .union(styles.map { NSAttributedString.Key($0.0 as String) })
        .union([
          NSAttributedString.Key(kAXMisspelledTextAttribute.takeUnretainedValue() as String),
          NSAttributedString.Key(kAXMarkedMisspelledTextAttribute.takeUnretainedValue() as String),
          NSAttributedString.Key(kAXAutocorrectedTextAttribute.takeUnretainedValue() as String),
          NSAttributedString.Key(kAXNaturalLanguageTextAttribute.takeUnretainedValue() as String),
          NSAttributedString.Key(kAXReplacementStringTextAttribute.takeUnretainedValue() as String),
        ])
        .union(neutral)
      // Do not silently strip attachments, links, superscripts or unknown layout attributes.
      if attrs.keys.contains(where: { !accepted.contains($0) }) {
        failure = .unsupportedFormat
        return
      }
      output.setAttributes(native, range: range)
    }
    if let failure { throw failure }
    return output
  }

  /// Unchanged graphemes keep their runs; inserted runs inherit the first replaced character.
  public static func replacement(source: NSAttributedString, text: String) throws
    -> NSAttributedString
  {
    guard source.length > 0, source.length <= 600, text.utf16.count <= 900 else {
      throw NativePasteError.unsupportedFormat
    }
    let original = try normalize(source)
    let before = Array(original.string)
    let after = Array(text)
    var offsets = [0]
    for character in before { offsets.append(offsets.last! + String(character).utf16.count) }
    var removed: Set<Int> = []
    var inserted: Set<Int> = []
    for change in after.difference(from: before) {
      switch change {
      case .remove(let offset, _, _): removed.insert(offset)
      case .insert(let offset, _, _): inserted.insert(offset)
      }
    }
    let output = NSMutableAttributedString(string: "")
    var i = 0
    var j = 0
    while i < before.count || j < after.count {
      var firstRemoved: Int?
      while i < before.count, removed.contains(i) {
        if firstRemoved == nil { firstRemoved = i }
        i += 1
      }
      let inheritance = firstRemoved ?? min(i, before.count - 1)
      while j < after.count, inserted.contains(j) {
        output.append(
          NSAttributedString(
            string: String(after[j]),
            attributes: original.attributes(at: offsets[inheritance], effectiveRange: nil)))
        j += 1
      }
      if i < before.count, j < after.count, !removed.contains(i), !inserted.contains(j) {
        guard before[i] == after[j] else { throw NativePasteError.unsupportedFormat }
        output.append(
          original.attributedSubstring(
            from: NSRange(location: offsets[i], length: offsets[i + 1] - offsets[i])))
        i += 1
        j += 1
      } else if i == before.count, j == after.count {
        break
      } else if firstRemoved == nil {
        throw NativePasteError.unsupportedFormat
      }
    }
    guard output.string == text else { throw NativePasteError.unsupportedFormat }
    return output
  }
}
