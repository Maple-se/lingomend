import Foundation

public enum SentenceIntent: String, Codable, Sendable {
    case fillGaps = "fill_gaps", correctEnglish = "correct_english", translate = "translate"
    public var label: String {
        switch self { case .fillGaps: "补表达"; case .correctEnglish: "英文修正"; case .translate: "英文表达" }
    }
}

public enum SentenceAdviceStatus: String, Codable, Sendable { case suggest, unchanged, clarify, unsupported }

public enum SentenceInputError: Error, Equatable, Sendable { case unsupported }

/// All fields describe one complete sentence. Left/right are immutable outside the selected target.
public struct SentenceRequest: Codable, Equatable, Sendable {
    public let target: String
    public let left: String
    public let right: String
    public let intent: SentenceIntent
    public var sentence: String { left + target + right }
    public var isSelection: Bool { !left.isEmpty || !right.isEmpty }

    public init(target: String, left: String = "", right: String = "") throws {
        self.target = target; self.left = left; self.right = right
        guard !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CoachingProviderError.emptyInput }
        guard (left + target + right).utf16.count <= 600 else { throw CoachingProviderError.inputTooLarge }
        let sentence = left + target + right
        guard !sentence.contains(where: { $0.isNewline }),
              !sentence.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              sentence.range(of: #"https?://|www\.|[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}|[`{}=<>]"#, options: .regularExpression) == nil
        else { throw SentenceInputError.unsupported }
        let han = target.range(of: #"\p{Han}"#, options: .regularExpression) != nil
        let english = sentence.range(of: "[A-Za-z]", options: .regularExpression) != nil
        guard han || english else { throw SentenceInputError.unsupported }
        self.intent = han ? (english ? .fillGaps : .translate) : .correctEnglish
    }

    public func validate() throws {
        // Reconstruct rather than trust a decoded intent or limits.
        let checked = try Self(target: target, left: left, right: right)
        guard checked.intent == intent else { throw CoachingProviderError.invalidResponse }
    }
}

public struct SentenceAdvice: Codable, Equatable, Sendable {
    public let status: SentenceAdviceStatus
    public let replacement: String
    public let message: String
    public init(status: SentenceAdviceStatus, replacement: String = "", message: String = "") {
        self.status = status; self.replacement = replacement; self.message = message
    }

    public func validate(for request: SentenceRequest) throws {
        try request.validate()
        guard message.utf16.count <= 160,
              !message.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw CoachingProviderError.invalidResponse
        }
        guard status == .suggest else {
            guard replacement.isEmpty, status == .unchanged || !message.isEmpty else {
                throw CoachingProviderError.invalidResponse
            }
            return
        }
        guard !replacement.isEmpty, replacement != request.target, replacement.utf16.count <= 900,
              !replacement.contains(where: { $0.isNewline }), !replacement.contains("`"),
              replacement.range(of: #"https?://|[`{}=<>]"#, options: .regularExpression) == nil,
              replacement.range(of: "[A-Za-z]", options: .regularExpression) != nil,
              !replacement.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format
              }) else { throw CoachingProviderError.invalidResponse }
        let result = request.left + replacement + request.right
        let left = request.left.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = request.right.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !(left.split(separator: " ").count >= 2 && replacement.hasPrefix(left)),
              !(right.split(separator: " ").count >= 2 && replacement.hasSuffix(right)) else {
            throw CoachingProviderError.invalidResponse
        }
        // Mechanical anchors complement the prompt; they do not establish semantic equivalence.
        for pattern in [#"\d+(?:[.,]\d+)*"#, #"\b[A-Z][A-Z0-9-]+\b"#,
                        #"\d+(?:\.\d+)?\s*(?:mA|kA|A|mV|kV|V|kW|W|MHz|kHz|Hz|ms|s|mm|cm|m|%)\b"#] {
            guard matches(pattern, in: request.sentence) == matches(pattern, in: result) else {
                throw CoachingProviderError.invalidResponse
            }
        }
        let hedges = #"(?i)\b(?:may|might|could|must|should|will|never|not|cannot|can't|don't|doesn't|isn't|won't)\b"#
        let before = matches(hedges, in: request.sentence).map { $0.lowercased() }
        let after = matches(hedges, in: result).map { $0.lowercased() }
        for token in Set(before) {
            guard before.filter({ $0 == token }).count <= after.filter({ $0 == token }).count else {
                throw CoachingProviderError.invalidResponse
            }
        }
        if request.sentence.contains("可能"),
           result.range(of: #"(?i)\b(?:may|might|could|possible|possibly|probably)\b"#, options: .regularExpression) == nil {
            throw CoachingProviderError.invalidResponse
        }
        // Literal quotations outside an explicitly selected fragment remain intact.
        if !request.isSelection {
            for quote in matches(#"“[^”]*”|「[^」]*」|\"[^\"]*\""#, in: request.sentence) {
                guard result.contains(quote) else { throw CoachingProviderError.invalidResponse }
            }
        }
    }

    private func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).map { source.substring(with: $0.range) }
    }
}

public protocol SentenceAdvising: Sendable {
    func advice(_ request: SentenceRequest) async throws -> SentenceAdvice
}
