import CoachCore
import PlatformBridge

public enum ReadingProposal {
    public static func request(for scope: ReadingScope) throws -> ReadingRequest {
        let kind: ReadingContextKind
        switch scope.availability {
        case .sentence: kind = .sentence
        case .excerpt: kind = .excerpt
        case .selectionOnly: kind = .selectionOnly
        }
        return try ReadingRequest(selection: scope.selection, before: scope.before,
                                  after: scope.after, contextKind: kind)
    }
}
