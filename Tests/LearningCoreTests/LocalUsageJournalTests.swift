import Foundation
import LearningCore
import XCTest

final class LocalUsageJournalTests: XCTestCase {
    func testAggregatesWithoutStoringDraft() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LingoMendUsageTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("usage.json")
        let journal = LocalUsageJournal(fileURL: file)
        try await journal.record(source: "PRIVATE_SENTENCE 轻载条件下", suggestion: "PRIVATE_SENTENCE under light-load conditions")
        try await journal.recordAcceptance(replaced: true)
        let summary = try await journal.summary()
        XCTAssertEqual(summary.requests, 1)
        XCTAssertEqual(summary.replaced, 1)
        XCTAssertGreaterThan(summary.chineseFraction, 0)
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("PRIVATE_SENTENCE"))
        try await journal.clear()
        let cleared = try await journal.summary()
        XCTAssertEqual(cleared, UsageSummary())
    }
}
