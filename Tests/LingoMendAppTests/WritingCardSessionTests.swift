import AppKit
import CoachCore
@testable import LingoMendApp
import MVPFlow
import PlatformBridge
import XCTest

@MainActor
final class WritingCardSessionTests: XCTestCase {
    private func proposal(status: SentenceAdviceStatus = .suggest) throws -> SentenceProposal {
        let text = "I very like 这个方案."
        let snapshot = TextSnapshot(applicationIdentifier: "com.apple.TextEdit",
            focusedElementIdentifier: "synthetic-editor", text: text,
            selectedRange: NSRange(location: 3, length: 0), revisionToken: "1")
        return try SentenceProposal(snapshot: snapshot,
            scope: WritingScopeResolver().resolve(snapshot),
            advice: SentenceAdvice(status: status,
                replacement: status == .suggest ? "I really like this approach." : ""))
    }

    func testLoadingCannotAcceptAndDismissesOnce() {
        let session = WritingCardSession()
        var dismissed = 0
        session.start { dismissed += 1 }
        XCTAssertEqual(session.phase, .loading)
        XCTAssertFalse(session.canAccept)
        session.accept()
        session.dismiss(); session.dismiss()
        XCTAssertEqual(dismissed, 1)
        XCTAssertEqual(session.phase, .hidden)
    }

    func testSameSessionMovesFromLoadingToCandidateToAcceptanceAndCompletion() throws {
        let session = WritingCardSession()
        var accepted = 0
        session.start { }
        session.show(try proposal(), onAccept: { accepted += 1 }, onExplain: { nil })
        XCTAssertEqual(session.phase, .candidate)
        XCTAssertTrue(session.canAccept)
        session.accept()
        XCTAssertEqual(accepted, 1)
        XCTAssertTrue(session.beginAcceptance())
        XCTAssertEqual(session.phase, .accepting)
        XCTAssertNil(session.proposal)
        XCTAssertNil(session.explanation)
        session.accept()
        XCTAssertEqual(accepted, 1)
        session.completeAcceptance(message: "已接受")
        XCTAssertEqual(session.phase, .accepted)
        XCTAssertEqual(session.message, "已接受")
        XCTAssertFalse(session.canAccept)
    }

    func testDismissCannotInterruptPasteCleanup() throws {
        let session = WritingCardSession()
        var dismissed = false
        session.start { dismissed = true }
        session.show(try proposal(), onAccept: { }, onExplain: { nil })
        XCTAssertTrue(session.beginAcceptance())
        session.dismiss()
        XCTAssertFalse(dismissed)
        XCTAssertEqual(session.phase, .accepting)
    }

    func testCancelledSessionIgnoresLateCandidateAndClearsActions() throws {
        let session = WritingCardSession()
        var accepted = false
        session.start { }
        session.hide()
        session.show(try proposal(), onAccept: { accepted = true }, onExplain: { nil })
        session.accept()
        XCTAssertEqual(session.phase, .hidden)
        XCTAssertFalse(accepted)
        XCTAssertNil(session.proposal)
    }

    func testNonSuggestionStillDisplaysButCannotAccept() throws {
        let session = WritingCardSession()
        session.start { }
        session.show(try proposal(status: .unchanged), onAccept: { XCTFail() }, onExplain: { nil })
        XCTAssertEqual(session.phase, .candidate)
        XCTAssertFalse(session.canAccept)
        XCTAssertFalse(session.beginAcceptance())
        session.accept()
    }

    func testStartingAgainDropsPreviousCandidateAndExplanation() throws {
        let session = WritingCardSession()
        session.start { }
        session.show(try proposal(), onAccept: { XCTFail() }, onExplain: { nil })
        session.start { }
        XCTAssertEqual(session.phase, .loading)
        XCTAssertNil(session.proposal)
        XCTAssertNil(session.explanation)
        XCTAssertFalse(session.canAccept)
    }

    func testReduceMotionDisablesWindowAnimation() {
        XCTAssertEqual(WritingCardMotion.duration(reduceMotion: true), 0)
        XCTAssertGreaterThan(WritingCardMotion.duration(reduceMotion: false), 0)
        XCTAssertLessThanOrEqual(WritingCardMotion.duration(reduceMotion: false), 0.2)
    }
}

@MainActor
final class WritingCardPlacementTests: XCTestCase {
    private let display = PanelPlacement.Display(
        frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 876))

    private func placement(anchor: CGRect) -> WritingCardPlacement {
        let expanded = PanelPlacement.frame(anchor: anchor,
            preferredSize: NSSize(width: 470, height: 400), fallback: .zero,
            primaryTop: 900, displays: [display])
        return WritingCardPlacement(expanded: expanded, anchor: anchor, primaryTop: 900)
    }

    func testBelowTextKeepsTopEdgeAndHorizontalPositionThroughExpansion() {
        let layout = placement(anchor: CGRect(x: 200, y: 100, width: 2, height: 20))
        XCTAssertTrue(layout.growsDownward)
        let loading = layout.frame(compact: true), result = layout.frame(compact: false)
        XCTAssertEqual(loading.maxY, result.maxY)
        XCTAssertEqual(loading.minX, result.minX)
        XCTAssertLessThan(loading.height, result.height)
    }

    func testNearBottomReservesSpaceAboveTextWithoutFlippingAfterLoading() {
        let layout = placement(anchor: CGRect(x: 200, y: 850, width: 2, height: 20))
        XCTAssertFalse(layout.growsDownward)
        let loading = layout.frame(compact: true), result = layout.frame(compact: false)
        XCTAssertEqual(loading.minY, result.minY)
        XCTAssertEqual(loading.minX, result.minX)
        XCTAssertGreaterThanOrEqual(result.minY, 50)
    }

    func testRightEdgeKeepsBothPhasesInsideDisplay() {
        let layout = placement(anchor: CGRect(x: 1400, y: 120, width: 2, height: 20))
        for compact in [true, false] {
            let frame = layout.frame(compact: compact)
            XCTAssertGreaterThanOrEqual(frame.minX, display.visibleFrame.minX + 8)
            XCTAssertLessThanOrEqual(frame.maxX, display.visibleFrame.maxX - 8)
            XCTAssertGreaterThanOrEqual(frame.minY, display.visibleFrame.minY + 8)
            XCTAssertLessThanOrEqual(frame.maxY, display.visibleFrame.maxY - 8)
        }
    }
}
