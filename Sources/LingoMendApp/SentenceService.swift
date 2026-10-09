import CoachCore
import Foundation

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

    init(preferences: AppPreferences, provider: (any SentenceAdvising)? = nil) {
        self.preferences = preferences; self.provider = provider
    }

    func advice(_ request: SentenceRequest) async throws -> SentenceAdvice {
        try Task.checkCancellation(); try request.validate()
        if let item = cache.last(where: { $0.0 == request && $0.2 > Date() }) { return item.1 }
        if preferences.networkEnabled {
            guard cooldownUntil <= Date() else { throw cooldownError }
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
