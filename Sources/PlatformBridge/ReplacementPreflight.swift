import Foundation

public enum ReplacementRefusal: Equatable, Sendable {
    case invalidCapture
    case focusChanged
    case sourceChanged
    case selectionChanged
    case invalidScope
}

/// A pure, conservative gate. The native bridge must acquire `current`
/// immediately before writing and choose copy-only on every refusal.
public struct ReplacementPreflight: Sendable {
    private let resolver: ParagraphScopeResolver

    public init(resolver: ParagraphScopeResolver = ParagraphScopeResolver()) {
        self.resolver = resolver
    }

    public func refusal(
        original: TextSnapshot,
        current: TextSnapshot,
        scope: ResolvedTextScope
    ) -> ReplacementRefusal? {
        if let refusal = rangeRefusal(original: original, current: current, range: scope.range, source: scope.text) {
            return refusal
        }
        guard resolver.resolve(snapshot: original) == scope else { return .invalidScope }
        return nil
    }

    /// Used for a precise inline placeholder, which is smaller than its paragraph.
    public func rangeRefusal(original: TextSnapshot, current: TextSnapshot,
                             range: NSRange, source: String) -> ReplacementRefusal? {
        guard !original.applicationIdentifier.isEmpty,
              !original.focusedElementIdentifier.isEmpty,
              !original.revisionToken.isEmpty,
              !current.applicationIdentifier.isEmpty,
              !current.focusedElementIdentifier.isEmpty,
              !current.revisionToken.isEmpty else {
            return .invalidCapture
        }

        guard original.applicationIdentifier == current.applicationIdentifier,
              original.focusedElementIdentifier == current.focusedElementIdentifier else {
            return .focusChanged
        }

        guard original.revisionToken == current.revisionToken,
              original.text == current.text else {
            return .sourceChanged
        }

        guard original.selectedRange == current.selectedRange else {
            return .selectionChanged
        }

        let fullText = original.text as NSString
        guard range.location != NSNotFound,
              range.location >= 0,
              range.length > 0,
              range.location <= fullText.length,
              range.length <= fullText.length - range.location,
              fullText.substring(with: range) == source else {
            return .invalidScope
        }
        return nil
    }
}
