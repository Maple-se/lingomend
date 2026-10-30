import DiagnosticsCore

public extension AccessibilityCaptureError {
    /// Fixed classification shared by initial capture and source revalidation.
    var diagnosticReason: DiagnosticReason {
        switch self {
        case .permissionRequired: .permissionRequired
        case .focusedElementUnavailable: .focusedElementUnavailable
        case .focusedWindowUnavailable: .focusedWindowUnavailable
        case .editableControlUnavailable: .editableControlUnavailable
        case .applicationUnavailable: .applicationUnavailable
        case .textUnavailable: .textUnavailable
        case .textTooLarge: .tooLong
        case .selectionUnavailable: .selectionUnavailable
        case .invalidSelection, .disjointSelection: .invalidRange
        case .focusChangedDuringCapture: .focusChangedDuringCapture
        case .protectedField: .protectedField
        case .applicationNotAllowed: .applicationNotAllowed
        }
    }
}

/// A single initial settling attempt, never a write/preflight retry. The caller
/// binds identity to the process and focused window, not to matching text.
@MainActor
enum CaptureSettling {
    static func run<Value>(sameSource: () -> Bool,
                           retrying: (AccessibilityCaptureError) -> Bool,
                           onRetry: (AccessibilityCaptureError) -> Void,
                           attempt: () throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        do { return try attempt() }
        catch let error as AccessibilityCaptureError where retrying(error) {
            onRetry(error)
            try await Task.sleep(for: .milliseconds(100))
            try Task.checkCancellation()
            guard sameSource() else { throw AccessibilityCaptureError.focusChangedDuringCapture }
            return try attempt()
        }
    }
}
