@testable import LingoMendApp
import CoachCore
import DiagnosticsCore
import Foundation
import XCTest

private final class EventSpy: DiagnosticRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(DiagnosticEvent, UUID?)] = []
    var events: [(DiagnosticEvent, UUID?)] { lock.withLock { stored } }
    func record(_ event: DiagnosticEvent, operation: UUID?) { lock.withLock { stored.append((event, operation)) } }
}
private actor TestSentenceProvider: SentenceAdvising {
    let error: CoachingProviderError?
    init(error: CoachingProviderError? = nil) { self.error = error }
    func advice(_ request: SentenceRequest) async throws -> SentenceAdvice {
        if let error { throw error }
        return SentenceAdvice(status: .unchanged)
    }
}
final class AppDiagnosticsTests: XCTestCase {
    @MainActor func testChannelPreferencesAreIndependentAndDoNotTouchAPISettings() async throws {
        let suite = "lingomend-diagnostics-test-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        defaults.set(Data("synthetic-existing-api-settings".utf8), forKey: "LingoMend.preferences.v1")
        let apiBefore = defaults.data(forKey: "LingoMend.preferences.v1")
        let development = AppDiagnostics(defaults: defaults, channel: .development, directory: root.appendingPathComponent("dev"))
        let release = AppDiagnostics(defaults: defaults, channel: .release, directory: root.appendingPathComponent("release"))
        XCTAssertTrue(development.enabled); XCTAssertFalse(release.enabled)
        await release.start()
        XCTAssertFalse(FileManager.default.fileExists(atPath: release.recorder.directory.path))
        await development.setEnabled(false)
        let relaunched = AppDiagnostics(defaults: defaults, channel: .development, directory: root.appendingPathComponent("dev"))
        XCTAssertFalse(relaunched.enabled)
        await development.reset(); XCTAssertTrue(development.enabled)
        XCTAssertNil(defaults.object(forKey: BuildChannel.development.preferenceKey))
        XCTAssertFalse(release.enabled)
        await development.setEnabled(false)
        await release.setEnabled(true); await release.setEnabled(false)
        XCTAssertEqual(defaults.data(forKey: "LingoMend.preferences.v1"), apiBefore)
    }
    @MainActor func testServiceCorrelationAndNoInputOrOutputFields() async throws {
        let spy = EventSpy(), operation = UUID()
        let service = SentenceService(preferences: AppPreferences(), provider: TestSentenceProvider(), diagnostics: spy)
        let request = try SentenceRequest(target: "SYNTHETIC_PRIVATE_DRAFT is safe.")
        _ = try await service.advice(request, operation: operation)
        _ = try await service.advice(request, operation: operation)
        XCTAssertEqual(spy.events.map { $0.0.name }, [.modelStarted, .providerInvoked, .modelCompleted, .modelStarted, .cacheHit, .modelCompleted])
        XCTAssertTrue(spy.events.allSatisfy { $0.1 == operation })
        let data = try JSONEncoder().encode(spy.events.map(\.0))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("SYNTHETIC_PRIVATE_DRAFT"))
    }
    @MainActor func testServiceEmitsOneTypedFailurePerOperationWithKnownHTTPCode() async throws {
        let spy = EventSpy(), operation = UUID()
        let service = SentenceService(preferences: AppPreferences(), provider: TestSentenceProvider(error: .httpStatus(503)), diagnostics: spy)
        do { _ = try await service.advice(SentenceRequest(target: "A synthetic sentence."), operation: operation); XCTFail() }
        catch { XCTAssertEqual(error as? CoachingProviderError, .httpStatus(503)) }
        XCTAssertEqual(spy.events.map { $0.0.name }, [.modelStarted, .providerInvoked, .modelFailed])
        XCTAssertEqual(spy.events.last?.0.reason, .http)
        XCTAssertEqual(spy.events.last?.0.httpStatus, 503)
        XCTAssertEqual(spy.events.last?.1, operation)
    }
    @MainActor func testCancelledRequestIsInfoNotError() async throws {
        let spy = EventSpy()
        let service = SentenceService(preferences: AppPreferences(), provider: TestSentenceProvider(), diagnostics: spy)
        let request = try SentenceRequest(target: "A synthetic sentence.")
        let task = Task { try await service.advice(request, operation: UUID()) }; task.cancel()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(spy.events.last?.0.outcome, .cancelled)
        XCTAssertEqual(spy.events.last?.0.level, .info)
    }
}
