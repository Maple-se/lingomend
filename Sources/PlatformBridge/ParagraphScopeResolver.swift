import Foundation

public struct ParagraphScopeResolver: Sendable {
    public let wholeFieldThreshold: Int

    public init(wholeFieldThreshold: Int = 280) {
        self.wholeFieldThreshold = wholeFieldThreshold
    }

    public func resolve(snapshot: TextSnapshot) -> ResolvedTextScope? {
        let source = snapshot.text as NSString
        let totalLength = source.length
        let selected = snapshot.selectedRange

        guard selected.location != NSNotFound,
              selected.location >= 0,
              selected.length >= 0,
              NSMaxRange(selected) <= totalLength else {
            return nil
        }

        if selected.length > 0 {
            return ResolvedTextScope(
                range: selected,
                text: source.substring(with: selected),
                kind: .explicitSelection
            )
        }

        let trimmedWholeField = snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if totalLength <= wholeFieldThreshold, !trimmedWholeField.contains("\n\n") {
            let range = source.range(of: trimmedWholeField)
            guard range.location != NSNotFound else { return nil }
            return ResolvedTextScope(
                range: range,
                text: trimmedWholeField,
                kind: .wholeShortField
            )
        }

        let caret = min(selected.location, totalLength)
        let beforeCaret = NSRange(location: 0, length: caret)
        let previousBreak = source.range(
            of: "\n",
            options: .backwards,
            range: beforeCaret
        )
        let paragraphStart = previousBreak.location == NSNotFound
            ? 0
            : NSMaxRange(previousBreak)

        let afterCaret = NSRange(location: caret, length: totalLength - caret)
        let nextBreak = source.range(of: "\n", options: [], range: afterCaret)
        let paragraphEnd = nextBreak.location == NSNotFound
            ? totalLength
            : nextBreak.location

        let paragraphRange = NSRange(
            location: paragraphStart,
            length: max(0, paragraphEnd - paragraphStart)
        )
        let paragraph = source.substring(with: paragraphRange)
        let leadingWhitespace = paragraph.prefix { $0.isWhitespace }.utf16.count
        let trailingWhitespace = paragraph.reversed().prefix { $0.isWhitespace }.utf16.count
        let trimmedRange = NSRange(
            location: paragraphRange.location + leadingWhitespace,
            length: max(0, paragraphRange.length - leadingWhitespace - trailingWhitespace)
        )

        guard trimmedRange.length > 0 else { return nil }
        return ResolvedTextScope(
            range: trimmedRange,
            text: source.substring(with: trimmedRange),
            kind: .paragraphAtCaret
        )
    }
}

