import Foundation

public enum WritingContext: String, Codable, CaseIterable, Sendable {
    case general
    case email
    case academic
    case chat
}

public enum CorrectionLevel: String, Codable, CaseIterable, Sendable {
    case correct
    case natural
}

public struct CoachRequest: Codable, Equatable, Sendable {
    public let sourceText: String
    public let context: WritingContext
    public let correctionLevel: CorrectionLevel

    public init(
        sourceText: String,
        context: WritingContext = .general,
        correctionLevel: CorrectionLevel = .natural
    ) {
        self.sourceText = sourceText
        self.context = context
        self.correctionLevel = correctionLevel
    }
}

public enum LearningCategory: String, Codable, CaseIterable, Sendable {
    case terminology
    case collocation
    case grammar
    case naturalness
    case tone
}

public struct LearningPoint: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let source: String
    public let target: String
    public let explanation: String
    public let category: LearningCategory
    public let acceptableVariants: [String]

    public init(
        id: UUID = UUID(),
        source: String,
        target: String,
        explanation: String,
        category: LearningCategory,
        acceptableVariants: [String] = []
    ) {
        self.id = id
        self.source = source
        self.target = target
        self.explanation = explanation
        self.category = category
        self.acceptableVariants = acceptableVariants
    }
}

public struct CoachResponse: Codable, Equatable, Sendable {
    public let naturalText: String
    public let meaningPreserved: Bool
    public let learningPoints: [LearningPoint]
    public let warnings: [String]

    public init(
        naturalText: String,
        meaningPreserved: Bool,
        learningPoints: [LearningPoint] = [],
        warnings: [String] = []
    ) {
        self.naturalText = naturalText
        self.meaningPreserved = meaningPreserved
        self.learningPoints = learningPoints
        self.warnings = warnings
    }
}

