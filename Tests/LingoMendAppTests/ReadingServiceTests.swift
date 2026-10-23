@testable import LingoMendApp
import CoachCore
import Foundation
import XCTest

private actor CountingReadingProvider: ReadingExplaining {
    private(set) var calls = 0
    let error: CoachingProviderError?
    init(error: CoachingProviderError? = nil) { self.error = error }
    func explain(_ request: ReadingRequest) async throws -> ReadingExplanation {
        calls += 1
        if let error { throw error }
        return ReadingExplanation(meaning: "含义", contextMeaning: request.contextKind == .selectionOnly ? "" : "实际语境解释")
    }
}

final class ReadingServiceTests: XCTestCase {
    @MainActor func testOnlyExplicitRequestsAndContextAwareCache() async throws {
        let provider = CountingReadingProvider()
        let service = ReadingService(preferences: AppPreferences(), provider: provider)
        let before = await provider.calls
        XCTAssertEqual(before, 0)
        let one = try ReadingRequest(selection: "current", before: "The ", after: " flows.", contextKind: .sentence)
        let two = try ReadingRequest(selection: "current", before: "Our ", after: " plan.", contextKind: .sentence)
        _ = try await service.explain(one); _ = try await service.explain(one)
        _ = try await service.explain(two)
        let after = await provider.calls
        XCTAssertEqual(after, 2)
    }

    @MainActor func testOfflineNeedsNoCredentials() async throws {
        let service = ReadingService(preferences: AppPreferences())
        let result = try await service.explain(ReadingRequest(selection: "current"))
        XCTAssertTrue(result.contextMeaning.isEmpty)
        XCTAssertTrue(result.meaning.contains("缺少上下文"))
    }

    @MainActor func testErrorsDoNotRetryOrFallback() async throws {
        var preferences = AppPreferences(); preferences.networkEnabled = true
        let provider = CountingReadingProvider(error: .rateLimited)
        let service = ReadingService(preferences: preferences, provider: provider)
        for _ in 0..<2 {
            do { _ = try await service.explain(ReadingRequest(selection: "current")); XCTFail("Expected rate limit") }
            catch { XCTAssertEqual(error as? CoachingProviderError, .rateLimited) }
        }
        let calls = await provider.calls
        XCTAssertEqual(calls, 1)
    }

    @MainActor func testCancelDuringThrottleDoesNotSend() async throws {
        var preferences = AppPreferences(); preferences.networkEnabled = true
        let provider = CountingReadingProvider(), service = ReadingService(preferences: preferences, provider: provider)
        _ = try await service.explain(ReadingRequest(selection: "current"))
        let task = Task { try await service.explain(ReadingRequest(selection: "coil")) }
        try await Task.sleep(for: .milliseconds(20)); task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let calls = await provider.calls
        XCTAssertEqual(calls, 1)
    }

    func testLegacyPreferencesKeepModelAndExplicitNetworkChoice() throws {
        var preferences = AppPreferences()
        preferences.networkEnabled = true
        preferences.provider.model = "synthetic-custom-model"
        preferences.allowedApplications = ["com.apple.TextEdit"]
        let encoded = try JSONEncoder().encode(preferences)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "globalAccessEnabled")
        let migrated = AppPreferences.decoded(try JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(migrated.networkEnabled)
        XCTAssertEqual(migrated.provider.model, "synthetic-custom-model")
        XCTAssertEqual(migrated.allowedApplications, ["com.apple.TextEdit"])
        XCTAssertFalse(migrated.globalAccessEnabled)
        preferences.globalAccessEnabled = true
        XCTAssertEqual(AppPreferences.decoded(try JSONEncoder().encode(preferences)), preferences)
    }
}
