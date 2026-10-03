import Foundation

public struct InlinePlaceholder: Equatable, Sendable {
    public let context: ResolvedTextScope
    public let range: NSRange
    public let text: String
}

/// Conservative mixed-English/Chinese detection, not an IME composition parser.
/// Only the nearest Han run in the current paragraph is eligible. The native
/// observer must wait for a quiet interval and discard on any input/focus change.
public struct InlinePlaceholderResolver: Sendable {
    public init() {}

    public func resolve(_ snapshot: TextSnapshot) -> InlinePlaceholder? {
        guard let context = ParagraphScopeResolver().resolve(snapshot: snapshot),
              context.text.utf16.count <= 1_000 else { return nil }
        let expression = try! NSRegularExpression(pattern: "[\\p{Han}]+")
        let string = context.text as NSString
        let matches = expression.matches(in: context.text, range: NSRange(location: 0, length: string.length))
        // A selected Chinese phrase is an explicit request even without English context.
        if context.kind == .explicitSelection,
           let match = matches.first, match.range.length == string.length, match.range.length <= 40 {
            return InlinePlaceholder(context: context, range: context.range, text: context.text)
        }
        guard snapshot.selectedRange.length == 0,
              context.text.unicodeScalars.contains(where: {
                  (65...90).contains($0.value) || (97...122).contains($0.value)
              }) else { return nil }
        let caret = snapshot.selectedRange.location
        for match in matches.reversed() {
            guard match.range.length <= 40 else { continue }
            let range = NSRange(location: context.range.location + match.range.location, length: match.range.length)
            let distance = caret - NSMaxRange(range)
            guard distance >= 0, distance <= 24 else { continue }
            // Do not assist while the user is typing a Latin transliteration
            // after the placeholder. Delimiters are allowed, unfinished words aren't.
            let tail = (snapshot.text as NSString).substring(with: NSRange(location: NSMaxRange(range), length: distance))
            guard tail.allSatisfy({ $0.isWhitespace || $0.isPunctuation }) else { continue }
            return InlinePlaceholder(context: context, range: range, text: string.substring(with: match.range))
        }
        return nil
    }
}
