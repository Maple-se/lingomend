import CoachCore
import Foundation
import PlatformBridge

public struct InlineProposal: Sendable {
    public let snapshot: TextSnapshot
    public let placeholder: InlinePlaceholder
    public let replacement: String
    public let response: CoachResponse
    public let learningPoint: LearningPoint?

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
