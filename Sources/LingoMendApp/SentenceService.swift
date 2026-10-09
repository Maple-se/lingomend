import CoachCore
import Foundation
import DiagnosticsCore

/// User-triggered requests only. Cache and errors remain in memory; no drafts are logged.
@MainActor
final class SentenceService {
    let preferences: AppPreferences
    var modeLabel: String { preferences.networkEnabled ? "DeepSeek · 按需求助" : "固定本地演示 · 按需求助" }
    private var provider: (any SentenceAdvising)?
    private var cache: [(SentenceRequest, SentenceAdvice, Date)] = []
    private var lastStart = Date.distantPast
    private var cooldownUntil = Date.distantPast
    private var cooldownError = CoachingProviderError.rateLimited
    private let diagnostics: any DiagnosticRecording

    init(preferences: AppPreferences, provider: (any SentenceAdvising)? = nil,
         diagnostics: any DiagnosticRecording = NoOpDiagnostics()) {
        self.preferences = preferences; self.provider = provider
        self.diagnostics = diagnostics
    }

    func advice(_ request: SentenceRequest, operation: UUID? = nil) async throws -> SentenceAdvice {
        let start = ContinuousClock.now
        let mode: DiagnosticMode = preferences.networkEnabled ? .network : .local
        diagnostics.record(DiagnosticEvent(.modelStarted, stage: .model, mode: mode), operation: operation)
        do {
            let result = try await generate(request, operation: operation)
            diagnostics.record(DiagnosticEvent(.modelCompleted, outcome: diagnosticAdviceOutcome(result),
                stage: .model, mode: mode, durationMS: diagnosticMilliseconds(since: start)), operation: operation)
            return result
        } catch {
            let status: Int? = if case CoachingProviderError.httpStatus(let code) = error { code } else { nil }
            diagnostics.record(DiagnosticEvent(.modelFailed, level: error is CancellationError ? .info : .error,
                outcome: error is CancellationError ? .cancelled : .failed, reason: diagnosticReason(error),
                stage: .model, mode: mode, durationMS: diagnosticMilliseconds(since: start), httpStatus: status), operation: operation)
            throw error
        }
    }

    private func generate(_ request: SentenceRequest, operation: UUID?) async throws -> SentenceAdvice {
        try Task.checkCancellation(); try request.validate()
        if let item = cache.last(where: { $0.0 == request && $0.2 > Date() }) {
            diagnostics.record(DiagnosticEvent(.cacheHit), operation: operation); return item.1
        }
        if preferences.networkEnabled {
            guard cooldownUntil <= Date() else {
                diagnostics.record(DiagnosticEvent(.cooldownRejected, outcome: .refused), operation: operation)
                throw cooldownError
            }
            if Date().timeIntervalSince(lastStart) < 3 {
                diagnostics.record(DiagnosticEvent(.throttleWait), operation: operation)
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
                provider = DeepSeekSentenceProvider(configuration: preferences.provider, apiKey: key)
            } else { provider = DemoSentenceProvider() }
        }
        do {
            diagnostics.record(DiagnosticEvent(.providerInvoked, stage: .model,
                mode: preferences.networkEnabled ? .network : .local), operation: operation)
            let result = try await provider!.advice(request)
            try Task.checkCancellation(); try result.validate(for: request)
            cache.append((request, result, Date().addingTimeInterval(60)))
            if cache.count > 8 { cache.removeFirst(cache.count - 8) }
            return result
        } catch let error as CoachingProviderError {
            if error == .rateLimited || error == .unauthorized {
                cooldownUntil = Date().addingTimeInterval(30); cooldownError = error
            }
            throw error
        }
    }
}
