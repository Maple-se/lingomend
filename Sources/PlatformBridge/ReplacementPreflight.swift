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

        let source = original.text as NSString
        guard scope.range.location != NSNotFound,
              scope.range.location >= 0,
              scope.range.length > 0,
              scope.range.location <= source.length,
              scope.range.length <= source.length - scope.range.location,
              source.substring(with: scope.range) == scope.text else {
            return .invalidScope
        }

        guard resolver.resolve(snapshot: original) == scope else {
            return .invalidScope
        }

        return nil
    }
}
