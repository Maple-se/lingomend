import CoachCore
import Foundation
import PlatformBridge

public struct InlineProposal: Sendable {
    public let snapshot: TextSnapshot
    public let placeholder: InlinePlaceholder
    public let replacement: String
    public let response: CoachResponse
    public let learningPoint: LearningPoint?

    /// Bound context independently of the model. Short fields may fit entirely.
    public static func request(for placeholder: InlinePlaceholder, context: WritingContext = .general,
                               correctionLevel: CorrectionLevel = .correct) -> ExpressionRequest? {
        let offset = placeholder.range.location - placeholder.context.range.location
        guard offset >= 0,
              let range = Range(NSRange(location: offset, length: placeholder.range.length), in: placeholder.context.text),
              String(placeholder.context.text[range]) == placeholder.text else { return nil }
        let left = bounded(String(placeholder.context.text[..<range.lowerBound]).reversed())
        let right = bounded(placeholder.context.text[range.upperBound...])
        return ExpressionRequest(source: placeholder.text, left: String(left.reversed()), right: right,
                                 context: context, correctionLevel: correctionLevel)
    }

    private static func bounded<S: Sequence>(_ characters: S) -> String where S.Element == Character {
        var result = ""
        for character in characters {
            guard result.utf16.count + String(character).utf16.count <= 200 else { break }
            result.append(character)
        }
        return result
    }

    public init?(snapshot: TextSnapshot, placeholder: InlinePlaceholder, replacement: String) {
        guard ExpressionRequest.validReplacement(replacement),
              let request = Self.request(for: placeholder),
              let range = Range(NSRange(location: placeholder.range.location - placeholder.context.range.location,
                                        length: placeholder.range.length), in: placeholder.context.text) else { return nil }
        var text = placeholder.context.text
        text.replaceSubrange(range, with: replacement)
        guard request.source == placeholder.text else { return nil }
        // Legacy response wrapper: the edit boundary is preserved locally.
        // This flag is not an independent proof of semantic equivalence.
        self.init(snapshot: snapshot, placeholder: placeholder,
                  response: CoachResponse(naturalText: text, meaningPreserved: true))
    }

    public func explainedResponse(_ point: LearningPoint?) -> CoachResponse {
        let anchored = point.flatMap { $0.source == placeholder.text && $0.target == replacement ? $0 : nil }
        return CoachResponse(naturalText: response.naturalText, meaningPreserved: true,
            learningPoints: anchored.map { [$0] } ?? [],
            warnings: anchored == nil ? ["服务未提供可靠解释；建议不代表语义已被独立验证。"] : [])
    }

    /// Accept only a bounded placeholder edit. Sentence-wide rewrites belong
    /// in the learning/review layer, never in an implicit inline acceptance.
    public init?(snapshot: TextSnapshot, placeholder: InlinePlaceholder, response: CoachResponse) {
        guard response.meaningPreserved,
              let localRange = Range(NSRange(location: placeholder.range.location - placeholder.context.range.location,
                                            length: placeholder.range.length), in: placeholder.context.text) else { return nil }
        let prefix = String(placeholder.context.text[..<localRange.lowerBound])
        let suffix = String(placeholder.context.text[localRange.upperBound...])
        guard response.naturalText.hasPrefix(prefix), response.naturalText.hasSuffix(suffix),
              response.naturalText.count >= prefix.count + suffix.count else { return nil }
        let replacement = String(response.naturalText.dropFirst(prefix.count).dropLast(suffix.count))
        guard !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              replacement != placeholder.text, replacement.utf16.count <= 240,
              !replacement.contains(where: { $0.isNewline }),
              !replacement.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) else { return nil }
        self.snapshot = snapshot
        self.placeholder = placeholder
        self.replacement = replacement
        self.response = response
        self.learningPoint = response.learningPoints.first { $0.source == placeholder.text && $0.target == replacement }
    }
}
