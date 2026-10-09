import Foundation

public struct TextSnapshot: Equatable, Sendable {
    public let applicationIdentifier: String
    /// Stable identity of the focused editable element for this capture session.
    /// The native bridge must not use an app identifier as a substitute.
    public let focusedElementIdentifier: String
    public let text: String
    public let selectedRange: NSRange
    public let revisionToken: String

    public init(
        applicationIdentifier: String,
        focusedElementIdentifier: String,
        text: String,
        selectedRange: NSRange,
        revisionToken: String
    ) {
        self.applicationIdentifier = applicationIdentifier
        self.focusedElementIdentifier = focusedElementIdentifier
        self.text = text
        self.selectedRange = selectedRange
        self.revisionToken = revisionToken
    }
}

public enum ScopeKind: String, Equatable, Sendable {
    case explicitSelection
    case sentenceAtCaret
    case paragraphAtCaret
    case wholeShortField
}

public struct ResolvedTextScope: Equatable, Sendable {
    public let range: NSRange
    public let text: String
    public let kind: ScopeKind

    public init(range: NSRange, text: String, kind: ScopeKind) {
        self.range = range
        self.text = text
        self.kind = kind
    }
}

public protocol FocusedTextReading: Sendable {
    func readFocusedText() async throws -> TextSnapshot
}

public protocol SafeTextReplacing: Sendable {
    func replace(
        scope: ResolvedTextScope,
        in original: TextSnapshot,
        with replacement: String
    ) async throws
}
