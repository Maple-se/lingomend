import CoachCore
import Foundation

public enum ExpressionState: String, Codable, CaseIterable, Sendable {
    case new
    case practicing
    case familiar
    case mastered
}

public struct Expression: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let sourcePhrase: String
    public let canonicalTarget: String
    public let targetPatterns: [String]
    public let category: LearningCategory
    public let shortContext: String?
    public let createdAt: Date
    public var state: ExpressionState
    public var confidence: Double

    public init(
        id: UUID = UUID(),
        sourcePhrase: String,
        canonicalTarget: String,
        targetPatterns: [String] = [],
        category: LearningCategory,
        shortContext: String? = nil,
        createdAt: Date = Date(),
        state: ExpressionState = .new,
        confidence: Double = 0
    ) {
        self.id = id
        self.sourcePhrase = sourcePhrase
        self.canonicalTarget = canonicalTarget
        self.targetPatterns = targetPatterns
        self.category = category
        self.shortContext = shortContext
        self.createdAt = createdAt
        self.state = state
        self.confidence = min(max(confidence, 0), 1)
    }

    public init(learningPoint: LearningPoint, shortContext: String? = nil) {
        self.init(
            sourcePhrase: learningPoint.source,
            canonicalTarget: learningPoint.target,
            targetPatterns: learningPoint.acceptableVariants,
            category: learningPoint.category,
            shortContext: shortContext
        )
    }
}

public enum EvidenceType: String, Codable, CaseIterable, Sendable {
    case assisted
    case independent
    case corrected
    case manual
}

public struct UsageEvidence: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let expressionID: UUID
    public let type: EvidenceType
    public let matchedText: String
    public let confidence: Double
    public let occurredAt: Date
    public let contextHash: String?

    public init(
        id: UUID = UUID(),
        expressionID: UUID,
        type: EvidenceType,
        matchedText: String,
        confidence: Double,
        occurredAt: Date = Date(),
        contextHash: String? = nil
    ) {
        self.id = id
        self.expressionID = expressionID
        self.type = type
        self.matchedText = matchedText
        self.confidence = min(max(confidence, 0), 1)
        self.occurredAt = occurredAt
        self.contextHash = contextHash
    }
}

