import Foundation

public enum CoachResponseValidationError: Error, Equatable, Sendable {
    case emptyNaturalText
    case meaningNotPreserved
    case tooManyLearningPoints(maximum: Int)
    case incompleteLearningPoint
    case oversizedResponse
    case unanchoredLearningPoint
}

public struct CoachResponseValidator: Sendable {
    public let maximumLearningPoints: Int

    public init(maximumLearningPoints: Int = 3) {
        self.maximumLearningPoints = maximumLearningPoints
    }

    public func validate(_ response: CoachResponse, sourceText: String? = nil) throws {
        guard response.naturalText.utf16.count <= 24_000,
              response.warnings.count <= 5,
              response.warnings.allSatisfy({ $0.count <= 1_000 }),
              response.learningPoints.allSatisfy({
                  $0.source.count <= 2_000 && $0.target.count <= 2_000
                      && $0.explanation.count <= 1_000 && $0.acceptableVariants.count <= 5
                      && $0.acceptableVariants.allSatisfy({ $0.count <= 2_000 })
              }) else { throw CoachResponseValidationError.oversizedResponse }
        if response.naturalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CoachResponseValidationError.emptyNaturalText
        }

        guard response.meaningPreserved else {
            throw CoachResponseValidationError.meaningNotPreserved
        }

        guard response.learningPoints.count <= maximumLearningPoints else {
            throw CoachResponseValidationError.tooManyLearningPoints(
                maximum: maximumLearningPoints
            )
        }

        let hasIncompletePoint = response.learningPoints.contains { point in
            point.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || point.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || point.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        if hasIncompletePoint {
            throw CoachResponseValidationError.incompleteLearningPoint
        }
        if let sourceText, response.learningPoints.contains(where: {
            !sourceText.contains($0.source) || !response.naturalText.contains($0.target)
        }) { throw CoachResponseValidationError.unanchoredLearningPoint }
    }
}
