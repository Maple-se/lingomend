import CoachCore
import Foundation
import MVPFlow
import PlatformBridge
import XCTest

final class SentenceProposalTests: XCTestCase {
    private func snapshot(_ text: String, range: NSRange? = nil) -> TextSnapshot {
        TextSnapshot(applicationIdentifier: "com.apple.TextEdit", focusedElementIdentifier: "synthetic-editor", text: text,
            selectedRange: range ?? NSRange(location: text.utf16.count, length: 0), revisionToken: "test")
    }

    func testSelectedPhraseGetsContextAndCannotEditNeighbours() throws {
        let text = "First stays. I am 负责 this project."
        let snapshot = snapshot(text, range: (text as NSString).range(of: "负责"))
        let scope = try SentenceScopeResolver().resolve(snapshot)
        let request = try SentenceProposal.request(for: scope)
        XCTAssertEqual(request.left, "I am "); XCTAssertEqual(request.right, " this project.")
        XCTAssertEqual(request.intent, .fillGaps)
        let proposal = try SentenceProposal(snapshot: snapshot, scope: scope,
            advice: SentenceAdvice(status: .suggest, replacement: "responsible for"))
        XCTAssertEqual(proposal.suggestedSentence, "I am responsible for this project.")
        XCTAssertEqual(proposal.scope.target.range, snapshot.selectedRange)
        XCTAssertFalse(proposal.request.sentence.contains("First stays"))
    }

    func testNecessaryEnglishChangesAreAllowedAndLabelled() throws {
        let snapshot = snapshot("I very like 这个方案.")
        let scope = try SentenceScopeResolver().resolve(snapshot)
        let proposal = try SentenceProposal(snapshot: snapshot, scope: scope,
            advice: SentenceAdvice(status: .suggest, replacement: "I really like this approach."))
        XCTAssertEqual(proposal.label, "补表达 · 包含英文修正")
        XCTAssertEqual(proposal.changes.filter { $0.kind != .inserted }.map(\.text).joined(), scope.target.text)
        XCTAssertEqual(proposal.changes.filter { $0.kind != .removed }.map(\.text).joined(), proposal.advice.replacement)
    }

    func testWholeSentenceFixturesCoverMultipleGapsEnglishAndChinese() async throws {
        for text in ["We need 降低损耗 without 增加成本.", "She go to the lab yesterday.", "这个方法可能会降低损耗。"] {
            let snapshot = snapshot(text), scope = try SentenceScopeResolver().resolve(snapshot)
            let request = try SentenceProposal.request(for: scope)
            let advice = try await DemoSentenceProvider().advice(request)
            let proposal = try SentenceProposal(snapshot: snapshot, scope: scope, advice: advice)
            XCTAssertEqual(proposal.advice.status, .suggest)
        }
    }

    func testSelectionRequiringEnglishChangeAsksForWholeSentence() async throws {
        let text = "I very like 这个方案."
        let snapshot = snapshot(text, range: (text as NSString).range(of: "这个方案"))
        let scope = try SentenceScopeResolver().resolve(snapshot)
        let advice = try await DemoSentenceProvider().advice(SentenceProposal.request(for: scope))
        XCTAssertEqual(advice.status, .clarify); XCTAssertTrue(advice.replacement.isEmpty)
    }

    func testUnchangedAndUnsupportedAreExplicit() async throws {
        let good = try await DemoSentenceProvider().advice(SentenceRequest(target: "I made a decision yesterday."))
        XCTAssertEqual(good.status, .unchanged)
        let other = try await DemoSentenceProvider().advice(SentenceRequest(target: "Another sentence."))
        XCTAssertEqual(other.status, .unsupported)
        let snapshot = snapshot("I made a decision yesterday."), scope = try SentenceScopeResolver().resolve(snapshot)
        let proposal = try SentenceProposal(snapshot: snapshot, scope: scope, advice: good)
        XCTAssertEqual(proposal.suggestedSentence, snapshot.text)
        XCTAssertTrue(proposal.changes.isEmpty)
    }

    func testScopeFromDifferentTextCannotProduceProposal() throws {
        let source = snapshot("This works 轻载条件下.")
        let scope = try SentenceScopeResolver().resolve(source)
        XCTAssertThrowsError(try SentenceProposal(snapshot: snapshot("A different document."), scope: scope,
            advice: SentenceAdvice(status: .suggest, replacement: "English.")))
    }
}
