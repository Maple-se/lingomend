import CoachCore
import Foundation
import PlatformBridge

/// Positions and edit authority are anchored locally, independent of model-generated text.
public struct SentenceProposal: Sendable {
    public let snapshot: TextSnapshot
    public let scope: SentenceScope
    public let request: SentenceRequest
    public let advice: SentenceAdvice
    public var suggestedSentence: String {
        advice.status == .suggest ? request.left + advice.replacement + request.right : request.sentence
    }
    public var changes: [DiffSegment] {
        advice.status == .suggest ? TextDiff().segments(from: request.target, to: advice.replacement) : []
    }
    public var label: String {
        guard advice.status == .suggest else {
            switch advice.status {
            case .unchanged: return "这句可以"
            case .clarify: return "需要确认"
            default: return "暂不处理"
            }
        }
        if request.intent == .fillGaps,
           changes.contains(where: { $0.kind == .removed && $0.text.range(of: "[A-Za-z]", options: .regularExpression) != nil }) {
            return "补表达 · 包含英文修正"
        }
        return request.intent.label
    }

    public static func request(for scope: SentenceScope) throws -> SentenceRequest {
        let offset = scope.target.range.location - scope.context.range.location
        guard offset >= 0,
              let range = Range(NSRange(location: offset, length: scope.target.range.length), in: scope.context.text),
              String(scope.context.text[range]) == scope.target.text else { throw SentenceScopeError.invalidRange }
        return try SentenceRequest(target: scope.target.text,
            left: String(scope.context.text[..<range.lowerBound]), right: String(scope.context.text[range.upperBound...]))
    }

    public init(snapshot: TextSnapshot, scope: SentenceScope, advice: SentenceAdvice) throws {
        for item in [scope.context, scope.target] {
            guard let range = Range(item.range, in: snapshot.text), String(snapshot.text[range]) == item.text else {
                throw SentenceScopeError.invalidRange
            }
        }
        let request = try Self.request(for: scope)
        try advice.validate(for: request)
        self.snapshot = snapshot; self.scope = scope; self.request = request; self.advice = advice
    }
}
