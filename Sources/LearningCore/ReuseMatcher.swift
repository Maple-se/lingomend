import Foundation

public struct ReuseMatch: Equatable, Sendable {
    public let expressionID: UUID
    public let matchedText: String
    public let confidence: Double
    public let isCanonical: Bool
}

public struct ReuseMatcher: Sendable {
    public init() {}

    public func match(expression: Expression, in originalDraft: String) -> ReuseMatch? {
        let normalizedDraft = normalize(originalDraft)
        let canonical = normalize(expression.canonicalTarget)

        if containsPhrase(canonical, in: normalizedDraft) {
            return ReuseMatch(
                expressionID: expression.id,
                matchedText: expression.canonicalTarget,
                confidence: 1,
                isCanonical: true
            )
        }

        for pattern in expression.targetPatterns {
            let normalizedPattern = normalize(pattern)
            if containsPhrase(normalizedPattern, in: normalizedDraft) {
                return ReuseMatch(
                    expressionID: expression.id,
                    matchedText: pattern,
                    confidence: 0.85,
                    isCanonical: false
                )
            }
        }

        return nil
    }

    private func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func containsPhrase(_ phrase: String, in draft: String) -> Bool {
        guard !phrase.isEmpty else { return false }
        return draft.range(of: phrase) != nil
    }
}
