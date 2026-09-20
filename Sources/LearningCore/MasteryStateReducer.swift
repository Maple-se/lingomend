import Foundation

public struct MasteryPolicy: Equatable, Sendable {
    public let familiarDistinctDays: Int
    public let masteredDistinctDays: Int
    public let minimumConfidence: Double

    public init(
        familiarDistinctDays: Int = 2,
        masteredDistinctDays: Int = 3,
        minimumConfidence: Double = 0.8
    ) {
        self.familiarDistinctDays = familiarDistinctDays
        self.masteredDistinctDays = masteredDistinctDays
        self.minimumConfidence = minimumConfidence
    }
}

public struct MasteryStateReducer: Sendable {
    public let policy: MasteryPolicy

    public init(policy: MasteryPolicy = MasteryPolicy()) {
        self.policy = policy
    }

    public func state(for evidence: [UsageEvidence]) -> ExpressionState {
        let qualifyingIndependent = evidence.filter {
            $0.type == .independent && $0.confidence >= policy.minimumConfidence
        }

        guard !qualifyingIndependent.isEmpty else { return .new }

        let correctedAfterIndependent = evidence.contains { $0.type == .corrected }
        let distinctDays = Set(qualifyingIndependent.map { dayKey(for: $0.occurredAt) }).count

        if distinctDays >= policy.masteredDistinctDays && !correctedAfterIndependent {
            return .mastered
        }

        if distinctDays >= policy.familiarDistinctDays {
            return .familiar
        }

        return .practicing
    }

    private func dayKey(for date: Date) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.dateComponents([.year, .month, .day], from: date)
    }
}
