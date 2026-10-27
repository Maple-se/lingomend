@testable import LingoMendApp
import CoachCore
import Foundation
import XCTest

private actor SyntheticReviewTransport: CoachingHTTPTransport {
    private let base = URLSessionCoachingTransport()
    private var response: String?
    func send(_ request: URLRequest) async throws -> CoachingHTTPResult {
        response = nil
        let result = try await base.send(request)
        if let envelope = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any],
           let choices = envelope["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any] {
            response = message["content"] as? String
        }
        return result
    }
    func syntheticResponse() -> String? { response }
}

/// Opt-in review of public synthetic cases through the app's actual service.
/// Default swift test never reads credentials or sends a request for this suite.
final class LiveSentenceQualityTests: XCTestCase {
    private struct ReviewCase: Codable {
        let id: String
        let target: String
        let left: String
        let right: String
        let expectedStatuses: [String]
        let check: String
        func request() throws -> SentenceRequest { try SentenceRequest(target: target, left: left, right: right) }
    }
    private func cases() throws -> [ReviewCase] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "sentence-quality", withExtension: "json",
                                                 subdirectory: "Fixtures"))
        return try JSONDecoder().decode([ReviewCase].self, from: Data(contentsOf: url))
    }
    func testSyntheticReviewCasesRespectRequestBoundaries() throws {
        for item in try cases() { try item.request().validate() }
    }
    @MainActor func testLiveSyntheticReview() async throws {
        guard ProcessInfo.processInfo.environment["LINGOMEND_LIVE_QUALITY"] == "1" else {
            throw XCTSkip("Explicit opt-in required; no credentials read or network requests sent.")
        }
        let defaults = UserDefaults(suiteName: "com.maplese.lingomend")
        let data = try XCTUnwrap(defaults?.data(forKey: "LingoMend.preferences.v1"), "Configure the app first.")
        let preferences = AppPreferences.decoded(data)
        guard preferences.networkEnabled else { throw XCTSkip("The app's model service is disabled.") }
        let key = try ProviderCredentials.read(for: preferences.provider)
        guard !key.isEmpty else { throw XCTSkip("No configured credential is available.") }
        let transport = SyntheticReviewTransport()
        let service = SentenceService(preferences: preferences,
            provider: DeepSeekSentenceProvider(configuration: preferences.provider, apiKey: key, transport: transport))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("Diagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("sentence-quality-review.json")
        var results: [[String: Any]] = []
        let selected = Set((ProcessInfo.processInfo.environment["LINGOMEND_QUALITY_CASES"] ?? "")
            .split(separator: ",").map(String.init))
        if !selected.isEmpty, let previous = try? Data(contentsOf: output),
           let report = try? JSONSerialization.jsonObject(with: previous) as? [String: Any] {
            results = report["results"] as? [[String: Any]] ?? []
        }
        for item in try cases() where selected.isEmpty || selected.contains(item.id) {
            results.removeAll { $0["id"] as? String == item.id }
            var stop = false
            do {
                let advice = try await service.advice(item.request())
                results.append(["id": item.id, "target": item.target, "left": item.left, "right": item.right,
                    "status": advice.status.rawValue, "replacement": advice.replacement, "message": advice.message,
                    "expectedStatuses": item.expectedStatuses, "check": item.check,
                    "statusMatches": item.expectedStatuses.contains(advice.status.rawValue)])
            } catch {
                var result: [String: Any] = ["id": item.id, "error": providerMessage(error), "check": item.check]
                result["syntheticResponse"] = await transport.syntheticResponse()
                results.append(result)
                if let error = error as? CoachingProviderError {
                    switch error {
                    case .unauthorized, .rateLimited, .network, .timedOut, .httpStatus: stop = true
                    default: break
                    }
                } else { stop = true }
            }
            // Only synthetic cases/results. Never save the key, endpoint or live drafts.
            let report: [String: Any] = ["model": preferences.provider.model, "results": results,
                "semanticReview": "Pending human review; status matching is not semantic acceptance."]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: output, options: .atomic)
            if stop { break } // Stop service failures; do not retry rejected cases.
        }
    }
}
