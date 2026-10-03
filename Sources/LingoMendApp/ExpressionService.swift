import CoachCore
import Foundation

/// One session shared by both editors. Configuration changes replace this object.
/// An in-memory cache only; no drafts, requests, responses or keys are serialized.
@MainActor
final class ExpressionService {
    let preferences: AppPreferences
    var modeLabel: String { preferences.networkEnabled ? "DeepSeek API · 联网" : "固定本地演示 · 不联网" }
    private var provider: (any ExpressionProviding)?
    private var lastStart = Date.distantPast
    private var cooldownUntil = Date.distantPast
    private var cooldownError = CoachingProviderError.rateLimited
    private var cache: [(ExpressionRequest, String?, Date)] = []

    init(preferences: AppPreferences, provider: (any ExpressionProviding)? = nil) {
        self.preferences = preferences; self.provider = provider
    }

    private func resolvedProvider() throws -> any ExpressionProviding {
        if let provider { return provider }
        let result: any ExpressionProviding
        if preferences.networkEnabled {
            let key = try ProviderCredentials.read(for: preferences.provider)
            guard !key.isEmpty else { throw CoachingProviderError.unauthorized }
            result = DeepSeekExpressionProvider(configuration: preferences.provider, apiKey: key)
        } else { result = DemoExpressionProvider() }
        provider = result
        return result
    }

    func candidate(_ request: ExpressionRequest) async throws -> String? {
        try Task.checkCancellation()
        if let entry = cache.last(where: { $0.0 == request && $0.2 > Date() }) { return entry.1 }
        if preferences.networkEnabled {
            guard cooldownUntil <= Date() else { throw cooldownError }
            while Date().timeIntervalSince(lastStart) < 3 {
                try await Task.sleep(for: .seconds(3 - Date().timeIntervalSince(lastStart)))
            }
            try Task.checkCancellation()
            guard cooldownUntil <= Date() else { throw cooldownError }
            lastStart = Date()
        }
        do {
            let result = try await resolvedProvider().candidate(request)
            try Task.checkCancellation()
            cache.append((request, result, Date().addingTimeInterval(result == nil ? 10 : 60)))
            if cache.count > 8 { cache.removeFirst(cache.count - 8) }
            return result
        } catch CoachingProviderError.rateLimited {
            cooldownUntil = Date().addingTimeInterval(30)
            cooldownError = .rateLimited
            throw CoachingProviderError.rateLimited
        } catch CoachingProviderError.unauthorized {
            cooldownUntil = Date().addingTimeInterval(30)
            cooldownError = .unauthorized
            throw CoachingProviderError.unauthorized
        }
    }

    func explain(_ request: ExpressionRequest, replacement: String) async throws -> LearningPoint? {
        try Task.checkCancellation()
        return try await resolvedProvider().explain(request, replacement: replacement)
    }
}
