@testable import LingoMendApp
import CoachCore
import Foundation
import XCTest

private actor CountingSentences: SentenceAdvising {
    private(set) var calls = 0
    let error: CoachingProviderError?
    init(error: CoachingProviderError? = nil) { self.error = error }
    func advice(_ request: SentenceRequest) async throws -> SentenceAdvice {
        calls += 1
        if let error { throw error }
        return SentenceAdvice(status: .unchanged)
    }
}

private actor CountingWritingExplainer: WritingExplaining {
    private(set) var calls = 0
    let result: WritingExplanation?
    let error: CoachingProviderError?

    init(result: WritingExplanation? = nil, error: CoachingProviderError? = nil) {
        self.result = result; self.error = error
    }

    func explain(_ request: WritingExplanationRequest) async throws -> WritingExplanation? {
        calls += 1
        if let error { throw error }
        return result
    }
}

final class SentenceServiceTests: XCTestCase {
    @MainActor func testServiceDoesNothingUntilAskedAndCachesResults() async throws {
        var preferences = AppPreferences(); preferences.networkEnabled = true
        let provider = CountingSentences(), service = SentenceService(preferences: preferences, provider: provider)
        let before = await provider.calls
        XCTAssertEqual(before, 0)
        let request = try SentenceRequest(target: "I made a decision yesterday.")
        _ = try await service.advice(request); _ = try await service.advice(request)
        let after = await provider.calls
        XCTAssertEqual(after, 1)
    }

    @MainActor func testOfflineWholeSentenceNeedsNoCredential() async throws {
        let service = SentenceService(preferences: AppPreferences())
        let result = try await service.advice(SentenceRequest(target: "I very like 这个方案."))
        XCTAssertEqual(result.replacement, "I really like this approach.")
    }

    @MainActor func testRepeatedFailuresCooldownWithoutFallback() async throws {
        for error in [CoachingProviderError.rateLimited, .unauthorized] {
            var preferences = AppPreferences(); preferences.networkEnabled = true
            let provider = CountingSentences(error: error), service = SentenceService(preferences: preferences, provider: provider)
            for _ in 0..<2 {
                do { _ = try await service.advice(SentenceRequest(target: "This works 轻载条件下.")); XCTFail("Expected error") }
                catch { XCTAssertEqual(error as? CoachingProviderError, provider.error) }
            }
            let calls = await provider.calls
            XCTAssertEqual(calls, 1)
        }
    }

    @MainActor func testCancelledThrottleDoesNotSendAnotherRequest() async throws {
        var preferences = AppPreferences(); preferences.networkEnabled = true
        let provider = CountingSentences(), service = SentenceService(preferences: preferences, provider: provider)
        _ = try await service.advice(SentenceRequest(target: "First sentence."))
        let task = Task { try await service.advice(SentenceRequest(target: "Second sentence.")) }
        try await Task.sleep(for: .milliseconds(20)); task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let calls = await provider.calls
        XCTAssertEqual(calls, 1)
    }

    @MainActor func testWritingExplanationIsExplicitAndCachedSeparately() async throws {
        var preferences = AppPreferences(); preferences.networkEnabled = false
        let point = WritingExplanation(reason: "说明这次搭配。", category: .naturalness)
        let explainer = CountingWritingExplainer(result: point)
        let service = SentenceService(preferences: preferences,
            provider: DemoSentenceProvider(), explanationProvider: explainer)
        let request = try WritingExplanationRequest(
            request: SentenceRequest(target: "I very like 这个方案."),
            replacement: "I really like this approach.")
        let first = try await service.explain(request)
        let second = try await service.explain(request)
        XCTAssertEqual(first, point); XCTAssertEqual(second, point)
        let calls = await explainer.calls
        XCTAssertEqual(calls, 1)
    }

    @MainActor func testExplanationFailureDoesNotChangeTheAdviceResult() async throws {
        var preferences = AppPreferences(); preferences.networkEnabled = false
        let explainer = CountingWritingExplainer(error: .invalidResponse)
        let service = SentenceService(preferences: preferences,
            provider: DemoSentenceProvider(), explanationProvider: explainer)
        let request = try SentenceRequest(target: "I very like 这个方案.")
        let advice = try await service.advice(request)
        let explanationRequest = try WritingExplanationRequest(request: request,
            replacement: advice.replacement)
        do {
            _ = try await service.explain(explanationRequest)
            XCTFail("Expected explanation failure")
        } catch {
            XCTAssertEqual(error as? CoachingProviderError, .invalidResponse)
        }
        let afterFailure = try await service.advice(request)
        XCTAssertEqual(afterFailure, advice)
    }
}
