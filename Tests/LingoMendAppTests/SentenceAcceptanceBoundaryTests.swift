@testable import LingoMendApp
import CoachCore
import Foundation
import PlatformBridge
import XCTest

private struct FailingAcceptanceExplainer: WritingExplaining {
    func explain(_ request: WritingExplanationRequest) async throws -> WritingExplanation? {
        throw CoachingProviderError.invalidResponse
    }
}

final class SentenceAcceptanceBoundaryTests: XCTestCase {
    private func snapshot(_ text: String) -> TextSnapshot {
        TextSnapshot(applicationIdentifier: "com.apple.TextEdit",
            focusedElementIdentifier: "synthetic-editor", text: text,
            selectedRange: NSRange(location: 3, length: 0), revisionToken: "revision-1")
    }

    @MainActor func testExplanationFailureLeavesNativeAcceptancePlanValid() async throws {
        let original = snapshot("I very like 这个方案.\nSECOND_LINE_UNCHANGED")
        let scope = try WritingScopeResolver().resolve(original)
        let request = try SentenceRequest(target: scope.target.text)
        let service = SentenceService(preferences: AppPreferences(),
            provider: DemoSentenceProvider(), explanationProvider: FailingAcceptanceExplainer())
        let advice = try await service.advice(request)
        do {
            _ = try await service.explain(WritingExplanationRequest(request: request,
                replacement: advice.replacement))
            XCTFail("Expected explanation failure")
        } catch {
            XCTAssertEqual(error as? CoachingProviderError, .invalidResponse)
        }

        let plan = try SentenceEditPlan(original: original, scope: scope,
            replacement: advice.replacement)
        XCTAssertNil(plan.refusal(current: original))
        XCTAssertEqual(plan.expectedText, "I really like this approach.\nSECOND_LINE_UNCHANGED")
    }

    @MainActor func testLoadedExplanationDoesNotPermitAcceptingAChangedSource() async throws {
        let original = snapshot("I very like 这个方案.\nSECOND_LINE_UNCHANGED")
        let scope = try WritingScopeResolver().resolve(original)
        let request = try SentenceRequest(target: scope.target.text)
        let service = SentenceService(preferences: AppPreferences(),
            provider: DemoSentenceProvider(), explanationProvider: DemoSentenceProvider())
        let advice = try await service.advice(request)
        let explanation = try await service.explain(WritingExplanationRequest(request: request,
            replacement: advice.replacement))
        XCTAssertNotNil(explanation)

        let plan = try SentenceEditPlan(original: original, scope: scope,
            replacement: advice.replacement)
        let changed = snapshot("I very like 另一个方案.\nSECOND_LINE_UNCHANGED")
        XCTAssertEqual(plan.refusal(current: changed), .sourceChanged)
        XCTAssertNil(plan.refusal(current: original))
    }
}
