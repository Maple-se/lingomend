import CoachCore
import Foundation
import LearningCore
import XCTest

final class LocalLearningJournalTests: XCTestCase {
    func testExplicitSaveAndIndependentUsePersistWithoutFullDraft() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LingoMendJournalTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("learning.json")
        let journal = LocalLearningJournal(fileURL: fileURL)
        let now = Date()
        let point = LearningPoint(
            source: "轻载条件下",
            target: "under light-load conditions",
            explanation: "Under a light workload.",
            category: .terminology
        )

        _ = try await journal.save(point)
        let sameDay = try await journal.observeIndependentUse(
            in: "under light-load conditions",
            at: now
        )
        XCTAssertTrue(sameDay.isEmpty)
        let first = try await journal.observeIndependentUse(
            in: "Private context: under light-load conditions.",
            at: now.addingTimeInterval(86_400)
        )
        XCTAssertEqual(first.first?.state, .practicing)

        let repeated = try await journal.observeIndependentUse(
            in: "Again, under light-load conditions.",
            at: now.addingTimeInterval(86_500)
        )
        XCTAssertTrue(repeated.isEmpty)

        let second = try await journal.observeIndependentUse(
            in: "Under light-load conditions, it is stable.",
            at: now.addingTimeInterval(172_800)
        )
        XCTAssertEqual(second.first?.state, .familiar)

        let reopened = LocalLearningJournal(fileURL: fileURL)
        let expressions = try await reopened.expressions()
        XCTAssertEqual(expressions.count, 1)
        XCTAssertEqual(expressions.first?.state, .familiar)
        let stored = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(stored.contains("Private context"))
    }
}
