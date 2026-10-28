import CoachCore
import Foundation
import MVPFlow
import PlatformBridge
import XCTest

final class RecentSuggestionTests: XCTestCase {
    private func proposal() throws -> SentenceProposal {
        let text = "I very like 这个方案."
        let snapshot = TextSnapshot(applicationIdentifier: "com.apple.TextEdit",
            focusedElementIdentifier: "synthetic-editor", text: text,
            selectedRange: NSRange(location: text.utf16.count, length: 0), revisionToken: "r1")
        let scope = try WritingScopeResolver().resolve(snapshot)
        return try SentenceProposal(snapshot: snapshot, scope: scope,
            advice: SentenceAdvice(status: .suggest, replacement: "I really like this approach."))
    }

    func testRecentRecordKeepsOnlyAcceptedSentenceAndOptionalExplanation() throws {
        let item = RecentAcceptedSuggestion(proposal: try proposal(), explanation: nil)
        XCTAssertEqual(item.original, "I very like 这个方案.")
        XCTAssertEqual(item.accepted, "I really like this approach.")
        XCTAssertNil(item.explanation)
        XCTAssertEqual(item.extent, .sentence)
    }

    func testRecentStoreReplacesLatestAndCanClear() throws {
        var store = RecentSuggestionStore()
        let first = RecentAcceptedSuggestion(proposal: try proposal(), explanation: nil)
        store.remember(first)
        XCTAssertEqual(store.latest, first)
        store.clear()
        XCTAssertNil(store.latest)
    }

    func testSourceChangeCannotProduceTheRecentAcceptedRecord() throws {
        let original = try proposal()
        let changedText = "I very like 另一个方案."
        let changed = TextSnapshot(applicationIdentifier: "com.apple.TextEdit",
            focusedElementIdentifier: "synthetic-editor", text: changedText,
            selectedRange: NSRange(location: changedText.utf16.count, length: 0), revisionToken: "r1")
        XCTAssertThrowsError(try SentenceProposal(snapshot: changed, scope: original.scope,
            advice: original.advice))
    }
}
