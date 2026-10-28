import Foundation

/// The exact sentence or explicitly selected passage that produced a candidate.
/// The model may explain this pair, but it cannot change either anchor.
public struct WritingExplanationRequest: Equatable, Sendable {
    public let request: SentenceRequest
    public let replacement: String

    public init(request: SentenceRequest, replacement: String) throws {
        self.request = request
        self.replacement = replacement
        try validate()
    }

    public var original: String { request.sentence }
    public var accepted: String { request.left + replacement + request.right }

    public func validate() throws {
        // Reuse the same mechanical edit contract as acceptance. This keeps an
        // explanation tied to a candidate the editor could actually accept.
        try SentenceAdvice(status: .suggest, replacement: replacement).validate(for: request)
    }
}

/// A short, optional explanation of one already generated writing suggestion.
/// It contains no edit range and cannot authorize a replacement.
public struct WritingExplanation: Codable, Equatable, Sendable {
    public let reason: String
    public let category: LearningCategory
    public let acceptableVariants: [String]

    public init(reason: String, category: LearningCategory,
                acceptableVariants: [String] = []) {
        self.reason = reason
        self.category = category
        self.acceptableVariants = acceptableVariants
    }

    enum CodingKeys: String, CodingKey {
        case reason = "reason_zh"
        case category
        case acceptableVariants = "acceptable_variants"
    }

    public func validate(for request: WritingExplanationRequest) throws {
        try request.validate()
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, reason.utf16.count <= 600,
              acceptableVariants.count <= 3,
              acceptableVariants.allSatisfy(ExpressionRequest.validReplacement),
              ![reason].contains(where: { value in
                  value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
              }) else {
            throw CoachingProviderError.invalidResponse
        }
    }
}

public protocol WritingExplaining: Sendable {
    /// nil means the provider deliberately abstained; it does not block acceptance.
    func explain(_ request: WritingExplanationRequest) async throws -> WritingExplanation?
}
