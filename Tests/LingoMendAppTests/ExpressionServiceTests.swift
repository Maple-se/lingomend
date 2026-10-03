@testable import LingoMendApp
import CoachCore
import Foundation
import XCTest

private actor CountingExpressions: ExpressionProviding {
    private(set) var candidates = 0
    private(set) var explanations = 0
    let replacement: String?
    let failure: CoachingProviderError?
    init(replacement: String? = "under light-load conditions", failure: CoachingProviderError? = nil) {
        self.replacement = replacement; self.failure = failure
    }
    func candidate(_ request: ExpressionRequest) async throws -> String? {
        candidates += 1
        if let failure { throw failure }
        return replacement
    }
    func explain(_ request: ExpressionRequest, replacement: String) async throws -> LearningPoint? {
        explanations += 1
        return LearningPoint(source: request.source, target: replacement, explanation: "合成解释", category: .terminology)
    }
}

final class ExpressionServiceTests: XCTestCase {
    private let input = ExpressionRequest(source: "轻载条件下", left: "This works ", right: ".")

    func testDefaultConfigurationIsOfflineAndDeepSeekReady() throws {
        let preferences = AppPreferences()
        XCTAssertFalse(preferences.networkEnabled)
        XCTAssertFalse(preferences.immersiveEnabled)
        XCTAssertTrue(preferences.allowedApplications.isEmpty)
        XCTAssertFalse(preferences.experimentalAcceptance)
        XCTAssertEqual(preferences.provider, DeepSeekExpressionProvider.preset)
        let data = try JSONEncoder().encode(preferences)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).lowercased().contains("apikey"))
    }

    func testOldStageOneEmptyModelMigratesWithoutEnablingNetworkOrLosingAllowlist() throws {
        var old = AppPreferences()
        old.provider = ProviderConfiguration()
        old.allowedApplications = ["com.apple.TextEdit"]
        old.immersiveEnabled = true
        let decoded = AppPreferences.decoded(try JSONEncoder().encode(old))
        XCTAssertEqual(decoded.provider, DeepSeekExpressionProvider.preset)
        XCTAssertFalse(decoded.networkEnabled)
        XCTAssertEqual(decoded.allowedApplications, old.allowedApplications)
        XCTAssertTrue(decoded.immersiveEnabled)
    }

    func testExistingConfiguredEndpointIsPreserved() throws {
        var old = AppPreferences()
        old.provider = ProviderConfiguration(baseURL: "https://example.invalid/v1", model: "custom")
        let decoded = AppPreferences.decoded(try JSONEncoder().encode(old))
        XCTAssertEqual(decoded.provider, old.provider)
    }

    func testCredentialIdentityIsEndpointSpecificNotModelSpecificWithoutReadingKeychain() throws {
        let first = ProviderConfiguration(baseURL: "https://api.deepseek.com", model: "a")
        let second = ProviderConfiguration(baseURL: "https://api.deepseek.com/chat/completions/", model: "b")
        let otherPath = ProviderConfiguration(baseURL: "https://api.deepseek.com/v1", model: "a")
        let otherHost = ProviderConfiguration(baseURL: "https://example.invalid", model: "a")
        XCTAssertEqual(try ProviderCredentials.account(for: first), try ProviderCredentials.account(for: second))
        XCTAssertNotEqual(try ProviderCredentials.account(for: first), try ProviderCredentials.account(for: otherPath))
        XCTAssertNotEqual(try ProviderCredentials.account(for: first), try ProviderCredentials.account(for: otherHost))
    }

    @MainActor func testOfflinePathUsesDemoWithoutCredentials() async throws {
        let result = try await ExpressionService(preferences: AppPreferences()).candidate(input)
        XCTAssertEqual(result, "under light-load conditions")
    }

    @MainActor func testCandidateCacheAvoidsDuplicateRequestsAndDoesNotGenerateExplanations() async throws {
        var preferences = AppPreferences(); preferences.networkEnabled = true
        let provider = CountingExpressions()
        let service = ExpressionService(preferences: preferences, provider: provider)
        _ = try await service.candidate(input)
        _ = try await service.candidate(input)
        let calls = await provider.candidates
        let explanations = await provider.explanations
        XCTAssertEqual(calls, 1); XCTAssertEqual(explanations, 0)
        _ = try await service.explain(input, replacement: "under light-load conditions")
        let after = await provider.explanations
        XCTAssertEqual(after, 1)
    }

    @MainActor func testAbstentionIsCachedNotRetriedAsDemo() async throws {
        var preferences = AppPreferences(); preferences.networkEnabled = true
        let provider = CountingExpressions(replacement: nil)
        let service = ExpressionService(preferences: preferences, provider: provider)
        let first = try await service.candidate(input)
        let second = try await service.candidate(input)
        XCTAssertNil(first); XCTAssertNil(second)
        let count = await provider.candidates
        XCTAssertEqual(count, 1)
    }

    @MainActor func testHTTPFailuresHaveCooldownAndNoLocalFallback() async throws {
        for failure in [CoachingProviderError.rateLimited, .unauthorized] {
            var preferences = AppPreferences(); preferences.networkEnabled = true
            let provider = CountingExpressions(failure: failure)
            let service = ExpressionService(preferences: preferences, provider: provider)
            for _ in 0..<2 {
                do { _ = try await service.candidate(input); XCTFail("Expected service failure") }
                catch { XCTAssertEqual(error as? CoachingProviderError, failure) }
            }
            let count = await provider.candidates
            XCTAssertEqual(count, 1)
        }
    }

    @MainActor func testCancelledThrottleDoesNotSendNextRequest() async throws {
        var preferences = AppPreferences(); preferences.networkEnabled = true
        let provider = CountingExpressions()
        let service = ExpressionService(preferences: preferences, provider: provider)
        _ = try await service.candidate(input)
        let task = Task { try await service.candidate(ExpressionRequest(source: "提高效率")) }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let count = await provider.candidates
        XCTAssertEqual(count, 1)
    }

    func testErrorsAreSanitizedAndNeverUseUnderlyingDescriptions() {
        struct SensitiveError: Error, CustomStringConvertible { var description: String { "private-secret-body" } }
        XCTAssertFalse(providerMessage(SensitiveError()).contains("private-secret-body"))
        XCTAssertTrue(providerMessage(CoachingProviderError.httpStatus(402)).contains("余额"))
    }
}
