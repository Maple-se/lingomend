import CoachCore
import PlatformBridge

public enum CapturePreviewError: Error, Equatable, Sendable {
    case noUsableScope
}

public struct CapturePreviewSession: Sendable {
    public let snapshot: TextSnapshot
    public let scope: ResolvedTextScope
    public let response: CoachResponse

    public init(snapshot: TextSnapshot, scope: ResolvedTextScope, response: CoachResponse) {
        self.snapshot = snapshot
        self.scope = scope
        self.response = response
    }
}

public struct CapturePreviewService: Sendable {
    private let reader: any FocusedTextReading
    private let provider: any CoachingProvider
    private let resolver: ParagraphScopeResolver
    private let validator: CoachResponseValidator

    public init(
        reader: any FocusedTextReading,
        provider: any CoachingProvider,
        resolver: ParagraphScopeResolver = ParagraphScopeResolver(),
        validator: CoachResponseValidator = CoachResponseValidator()
    ) {
        self.reader = reader
        self.provider = provider
        self.resolver = resolver
        self.validator = validator
    }

    public func capture() async throws -> CapturePreviewSession {
        let snapshot = try await reader.readFocusedText()
        guard let scope = resolver.resolve(snapshot: snapshot) else {
            throw CapturePreviewError.noUsableScope
        }
        let response = try await provider.suggest(CoachRequest(sourceText: scope.text))
        try validator.validate(response)
        return CapturePreviewSession(snapshot: snapshot, scope: scope, response: response)
    }
}
