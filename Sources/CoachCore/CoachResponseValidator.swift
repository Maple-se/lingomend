import Foundation

public enum CoachResponseValidationError: Error, Equatable, Sendable {
    case emptyNaturalText
    case meaningNotPreserved
    case tooManyLearningPoints(maximum: Int)
    case incompleteLearningPoint
}

public struct CoachResponseValidator: Sendable {
    public let maximumLearningPoints: Int

    public init(maximumLearningPoints: Int = 3) {
        self.maximumLearningPoints = maximumLearningPoints
    }

    public func validate(_ response: CoachResponse) throws {
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
    }
}

