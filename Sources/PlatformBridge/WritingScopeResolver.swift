import Foundation

/// Caret requests remain sentence-scoped; larger scopes require an explicit selection.
public struct WritingScopeResolver: Sendable {
    public init() {}
    public func resolve(_ snapshot: TextSnapshot) throws -> SentenceScope {
        do { return try SentenceScopeResolver().resolve(snapshot) }
        catch SentenceScopeError.multipleSentences { return try selectedPassage(snapshot) }
        catch SentenceScopeError.tooLong {
            // A short fragment in an oversized sentence must not silently lose its context.
            guard snapshot.selectedRange.length > 600 else { throw SentenceScopeError.tooLong }
            return try selectedPassage(snapshot)
        }
    }

    private func selectedPassage(_ snapshot: TextSnapshot) throws -> SentenceScope {
        let selected = snapshot.selectedRange
        guard selected.length > 0, selected.location != NSNotFound,
              let range = Range(selected, in: snapshot.text),
              snapshot.text.isCharacterBoundary(range.lowerBound), snapshot.text.isCharacterBoundary(range.upperBound) else {
            throw SentenceScopeError.invalidRange
        }
        let text = String(snapshot.text[range])
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SentenceScopeError.empty }
        guard text.utf16.count <= 1_200 else { throw SentenceScopeError.tooLong }
        let target = ResolvedTextScope(range: selected, text: text, kind: .explicitSelection)
        return SentenceScope(context: target, target: target, isPassage: true)
    }
}

private extension String {
    func isCharacterBoundary(_ index: Index) -> Bool { index == endIndex || indices.contains(index) }
}
