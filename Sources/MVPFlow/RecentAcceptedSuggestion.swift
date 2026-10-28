import CoachCore
import Foundation

/// The smallest in-memory record needed to review the last accepted suggestion.
/// It intentionally omits the document snapshot, surrounding context and app identity.
public struct RecentAcceptedSuggestion: Equatable, Sendable {
    public let original: String
    public let accepted: String
    public let extent: WritingExtent
    public let explanation: WritingExplanation?

    public init(proposal: SentenceProposal, explanation: WritingExplanation?) {
        self.original = proposal.request.sentence
        self.accepted = proposal.suggestedSentence
        self.extent = proposal.request.extent
        self.explanation = explanation
    }

    public var extentLabel: String {
        extent == .selectedPassage ? "所选短段落" : "当前句子"
    }
}

/// A session-only store. T4.2 will decide whether voluntary expression cards
/// should be persisted; T4.1 does not write the recent suggestion to disk.
public struct RecentSuggestionStore: Equatable, Sendable {
    public private(set) var latest: RecentAcceptedSuggestion?

    public init(latest: RecentAcceptedSuggestion? = nil) { self.latest = latest }

    public mutating func remember(_ suggestion: RecentAcceptedSuggestion) {
        latest = suggestion
    }

    public mutating func clear() { latest = nil }
}
