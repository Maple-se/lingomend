import CoachCore
import DiagnosticsCore
import Foundation

@MainActor
final class ReadingService {
    private let preferences: AppPreferences
    private var provider: (any ReadingExplaining)?
    private let diagnostics: any DiagnosticRecording
    private var cache: [(ReadingRequest, ReadingExplanation, Date)] = []
    private var lastStart = Date.distantPast
    private var cooldownUntil = Date.distantPast
    private var cooldownError = CoachingProviderError.rateLimited

    init(preferences: AppPreferences, provider: (any ReadingExplaining)? = nil,
         diagnostics: any DiagnosticRecording = NoOpDiagnostics()) {
        self.preferences = preferences; self.provider = provider; self.diagnostics = diagnostics
    }

    func explain(_ request: ReadingRequest, operation: UUID? = nil) async throws -> ReadingExplanation {
        let start = ContinuousClock.now
        let mode: DiagnosticMode = preferences.networkEnabled ? .network : .local
        diagnostics.record(DiagnosticEvent(.modelStarted, stage: .model, mode: mode, shortcut: .read), operation: operation)
        do {
            try Task.checkCancellation(); try request.validate()
            if let item = cache.last(where: { $0.0 == request && $0.2 > Date() }) {
                diagnostics.record(DiagnosticEvent(.cacheHit, shortcut: .read), operation: operation)
                diagnostics.record(DiagnosticEvent(.modelCompleted, outcome: .success, stage: .model,
                    mode: mode, shortcut: .read, durationMS: diagnosticMilliseconds(since: start)), operation: operation)
                return item.1
            }
            if preferences.networkEnabled {
                guard cooldownUntil <= Date() else {
                    diagnostics.record(DiagnosticEvent(.cooldownRejected, outcome: .refused, shortcut: .read), operation: operation)
                    throw cooldownError
                }
                if Date().timeIntervalSince(lastStart) < 3 {
                    diagnostics.record(DiagnosticEvent(.throttleWait, shortcut: .read), operation: operation)
                }
                while Date().timeIntervalSince(lastStart) < 3 {
                    try await Task.sleep(for: .seconds(3 - Date().timeIntervalSince(lastStart)))
                }
                try Task.checkCancellation()
                guard cooldownUntil <= Date() else { throw cooldownError }
                lastStart = Date()
            }
            if provider == nil {
                if preferences.networkEnabled {
                    let key = try ProviderCredentials.read(for: preferences.provider)
                    guard !key.isEmpty else { throw CoachingProviderError.unauthorized }
                    provider = DeepSeekReadingProvider(configuration: preferences.provider, apiKey: key)
                } else { provider = DemoReadingProvider() }
            }
            diagnostics.record(DiagnosticEvent(.providerInvoked, stage: .model, mode: mode, shortcut: .read), operation: operation)
            let result = try await provider!.explain(request)
            try Task.checkCancellation(); try result.validate(for: request)
            cache.append((request, result, Date().addingTimeInterval(60)))
            if cache.count > 8 { cache.removeFirst(cache.count - 8) }
            diagnostics.record(DiagnosticEvent(.modelCompleted, outcome: .success, stage: .model,
                mode: mode, shortcut: .read, durationMS: diagnosticMilliseconds(since: start)), operation: operation)
            return result
        } catch {
            if let providerError = error as? CoachingProviderError,
               providerError == .rateLimited || providerError == .unauthorized {
                cooldownUntil = Date().addingTimeInterval(30); cooldownError = providerError
            }
            let status: Int? = if case CoachingProviderError.httpStatus(let code) = error { code } else { nil }
            diagnostics.record(DiagnosticEvent(.modelFailed, level: error is CancellationError ? .info : .error,
                outcome: error is CancellationError ? .cancelled : .failed, reason: diagnosticReason(error),
                stage: .model, mode: mode, shortcut: .read,
                durationMS: diagnosticMilliseconds(since: start), httpStatus: status), operation: operation)
            throw error
        }
    }
}
