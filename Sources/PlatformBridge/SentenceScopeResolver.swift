import Foundation

/// Context is read-only; the target is the user's edit permission, not a model decision.
public struct SentenceScope: Equatable, Sendable {
    public let context: ResolvedTextScope
    public let target: ResolvedTextScope
}

public enum SentenceScopeError: Error, Equatable, Sendable {
    case invalidRange, empty, multipleSentences, tooLong
}

/// Deterministic prose boundaries. Line breaks separate expressions; visual wraps do not.
/// Abbreviations and decimals are handled locally, with no draft sent to a tokenizer service.
public struct SentenceScopeResolver: Sendable {
    public let maximumLength: Int
    public init(maximumLength: Int = 600) { self.maximumLength = maximumLength }

    public func resolve(_ snapshot: TextSnapshot) throws -> SentenceScope {
        let text = snapshot.text as NSString
        let selected = snapshot.selectedRange
        guard selected.location != NSNotFound, selected.location >= 0, selected.length >= 0,
              selected.location <= text.length, selected.length <= text.length - selected.location,
              Range(selected, in: snapshot.text) != nil else { throw SentenceScopeError.invalidRange }
        var boundaries: Set<Int> = [0], offset = 0
        for character in snapshot.text {
            offset += String(character).utf16.count; boundaries.insert(offset)
        }
        guard boundaries.contains(selected.location), boundaries.contains(NSMaxRange(selected)) else {
            throw SentenceScopeError.invalidRange
        }

        // A new blank line is an empty expression, never permission to revisit the previous paragraph.
        let previousBreak = text.rangeOfCharacter(from: .newlines, options: .backwards,
            range: NSRange(location: 0, length: selected.location))
        let start = previousBreak.location == NSNotFound ? 0 : NSMaxRange(previousBreak)
        let nextBreak = text.rangeOfCharacter(from: .newlines, range:
            NSRange(location: selected.location, length: text.length - selected.location))
        let end = nextBreak.location == NSNotFound ? text.length : nextBreak.location
        guard NSMaxRange(selected) <= end else { throw SentenceScopeError.multipleSentences }
        let paragraphRange = NSRange(location: start, length: end - start)
        let paragraph = text.substring(with: paragraphRange)
        let sentences = ranges(in: paragraph).map { NSRange(location: start + $0.location, length: $0.length) }
        guard !sentences.isEmpty else { throw SentenceScopeError.empty }
        let chosen: NSRange
        if selected.length > 0 {
            guard let range = sentences.first(where: {
                selected.location >= $0.location && NSMaxRange(selected) <= NSMaxRange($0)
            }) else { throw SentenceScopeError.multipleSentences }
            chosen = range
        } else {
            // Whitespace after a completed sentence belongs to that sentence until next text begins.
            chosen = sentences.last(where: { $0.location <= selected.location }) ?? sentences[0]
        }
        guard chosen.length <= maximumLength else { throw SentenceScopeError.tooLong }
        let context = ResolvedTextScope(range: chosen, text: text.substring(with: chosen), kind: .sentenceAtCaret)
        let target = selected.length > 0
            ? ResolvedTextScope(range: selected, text: text.substring(with: selected), kind: .explicitSelection)
            : context
        guard !target.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SentenceScopeError.empty }
        return SentenceScope(context: context, target: target)
    }

    private func ranges(in paragraph: String) -> [NSRange] {
        let characters = Array(paragraph)
        var offsets = [0]
        for character in characters { offsets.append(offsets.last! + String(character).utf16.count) }
        var result: [NSRange] = [], start = 0, index = 0
        var closingQuote: Character?, parentheses = 0
        func append(_ end: Int) {
            var lower = start, upper = end
            while lower < upper, characters[lower].isWhitespace { lower += 1 }
            while upper > lower, characters[upper - 1].isWhitespace { upper -= 1 }
            if lower < upper { result.append(NSRange(location: offsets[lower], length: offsets[upper] - offsets[lower])) }
            start = end
        }
        while index < characters.count {
            let character = characters[index]
            if let close = closingQuote {
                if character == close {
                    closingQuote = nil
                    var next = index + 1
                    while next < characters.count, characters[next].isWhitespace { next += 1 }
                    if parentheses == 0, index > 0, ".!?。！？".contains(characters[index - 1]),
                       next == characters.count || characters[next].isUppercase {
                        append(index + 1)
                    }
                }
                index += 1; continue
            }
            if character == "“" || character == "「" || character == "\"" || character == "‘"
                || (character == "'" && (index == 0 || !characters[index - 1].isLetter)) {
                switch character {
                case "“": closingQuote = "”"
                case "「": closingQuote = "」"
                case "‘": closingQuote = "’"
                default: closingQuote = character
                }
                index += 1; continue
            }
            if character == "(" || character == "（" { parentheses += 1 }
            if character == ")" || character == "）" { parentheses = max(0, parentheses - 1) }
            let terminal = parentheses == 0 && ("!?。！？".contains(character)
                || (character == "." && periodEndsSentence(characters, at: index))
            )
            if terminal {
                var end = index + 1
                while end < characters.count, ".!?。！？\"”’')）」』]".contains(characters[end]) { end += 1 }
                append(end); index = end
            } else { index += 1 }
        }
        append(characters.count)
        return result
    }

    private func periodEndsSentence(_ text: [Character], at index: Int) -> Bool {
        let previous = index > 0 ? text[index - 1] : " "
        let next = index + 1 < text.count ? text[index + 1] : " "
        if previous.isNumber && next.isNumber { return false }
        if next.isLetter || next.isNumber || next == "." { return false }
        var start = index
        while start > 0, text[start - 1].isLetter || text[start - 1] == "." { start -= 1 }
        let token = String(text[start...index]).lowercased()
        let abbreviations: Set<String> = ["dr.", "mr.", "mrs.", "ms.", "prof.", "fig.", "no.",
            "vs.", "e.g.", "i.e.", "u.s.", "u.k.", "et.", "al."]
        if abbreviations.contains(token) { return false }
        if index - start == 1, text[start].isUppercase { return false }
        // A period surrounded by URL punctuation remains within that token.
        if next == "/" || next == "@" { return false }
        return true
    }
}
