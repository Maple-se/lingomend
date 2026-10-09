import Foundation

public enum SentenceEditError: Error, Equatable, Sendable {
  case invalidPlan, unchanged, unsupportedApplication
}

/// One contiguous, grapheme-aligned edit. No model-provided positions or whole-field writes.
public struct SentenceEditPlan: Equatable, Sendable {
  public let original: TextSnapshot
  public let scope: SentenceScope
  public let replacement: String
  public let range: NSRange
  public let source: String
  public let insertedText: String
  public let replacementRange: NSRange
  public let expectedText: String
  public let caretAfter: NSRange

  public init(original: TextSnapshot, scope: SentenceScope, replacement: String) throws {
    guard original.applicationIdentifier == "com.apple.TextEdit" else {
      throw SentenceEditError.unsupportedApplication
    }
    guard try SentenceScopeResolver().resolve(original) == scope,
      !replacement.isEmpty, replacement.utf16.count <= 900,
      !replacement.unicodeScalars.contains(where: {
        CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format
      })
    else { throw SentenceEditError.invalidPlan }
    guard scope.target.text != replacement else { throw SentenceEditError.unchanged }
    let before = Array(scope.target.text)
    let after = Array(replacement)
    var prefix = 0
    var suffix = 0
    while prefix < min(before.count, after.count), before[prefix] == after[prefix] { prefix += 1 }
    while suffix < min(before.count, after.count) - prefix,
      before[before.count - suffix - 1] == after[after.count - suffix - 1]
    { suffix += 1 }
    // An empty clipboard payload is not a reliable native deletion. Include one
    // unchanged neighbour inside the authorized target so paste still has text.
    if after.count - prefix - suffix == 0 {
      if suffix > 0 { suffix -= 1 } else if prefix > 0 { prefix -= 1 }
    }
    let prefixLength = String(before.prefix(prefix)).utf16.count
    let removed = String(before[prefix..<(before.count - suffix)])
    let inserted = String(after[prefix..<(after.count - suffix)])
    let editRange = NSRange(
      location: scope.target.range.location + prefixLength, length: removed.utf16.count)
    self.original = original
    self.scope = scope
    self.replacement = replacement
    range = editRange
    source = removed
    insertedText = inserted
    replacementRange = NSRange(location: prefixLength, length: inserted.utf16.count)
    expectedText = (original.text as NSString).replacingCharacters(in: editRange, with: inserted)
    caretAfter = NSRange(location: scope.target.range.location + replacement.utf16.count, length: 0)
  }

  public func refusal(current: TextSnapshot) -> ReplacementRefusal? {
    ReplacementPreflight().rangeRefusal(
      original: original, current: current,
      range: scope.target.range, source: scope.target.text)
  }
}
