import CoachCore
import Foundation
import MVPFlow
import PlatformBridge
import XCTest

final class InlineProposalTests: XCTestCase {
    private let text = "This works 轻载条件下."
    private func proposal(_ target: String, meaningPreserved: Bool = true) throws -> InlineProposal? {
        let snapshot = TextSnapshot(applicationIdentifier: "test", focusedElementIdentifier: "field", text: text,
            selectedRange: NSRange(location: text.utf16.count, length: 0), revisionToken: "r")
        let placeholder = try XCTUnwrap(InlinePlaceholderResolver().resolve(snapshot))
        return InlineProposal(snapshot: snapshot, placeholder: placeholder,
            response: CoachResponse(naturalText: target, meaningPreserved: meaningPreserved))
    }
    func testOnlyPlaceholderBecomesAcceptableReplacement() throws {
        XCTAssertEqual(try proposal("This works under light-load conditions.")?.replacement, "under light-load conditions")
    }
    func testShortCandidateIsAppliedLocallyWithUnchangedNeighbours() throws {
        let original = try XCTUnwrap(proposal("This works under light-load conditions."))
        let result = try XCTUnwrap(InlineProposal(snapshot: original.snapshot, placeholder: original.placeholder,
                                                replacement: "under light-load conditions"))
        XCTAssertEqual(result.response.naturalText, "This works under light-load conditions.")
        XCTAssertTrue(result.response.learningPoints.isEmpty)
        let request = try XCTUnwrap(InlineProposal.request(for: original.placeholder, context: .email))
        XCTAssertEqual(request.source, "轻载条件下")
        XCTAssertEqual(request.left, "This works ")
        XCTAssertEqual(request.right, ".")
        XCTAssertEqual(request.context, .email)
    }

    func testRequestContextIsCappedWithoutSplittingUnicodeOrLeakingOtherParagraphs() throws {
        let text = "OTHER_PARAGRAPH_MUST_NOT_LEAVE\n" + String(repeating: "a😀", count: 90)
            + " 轻载条件下. " + String(repeating: "b😀", count: 90)
        let offset = (text as NSString).range(of: "轻载条件下").location
        let snapshot = TextSnapshot(applicationIdentifier: "private.app", focusedElementIdentifier: "private-field",
            text: text, selectedRange: NSRange(location: offset + 5, length: 0), revisionToken: "private-revision")
        let placeholder = try XCTUnwrap(InlinePlaceholderResolver().resolve(snapshot))
        let request = try XCTUnwrap(InlineProposal.request(for: placeholder))
        XCTAssertLessThanOrEqual(request.left.utf16.count, 200)
        XCTAssertLessThanOrEqual(request.right.utf16.count, 200)
        try request.validate()
        let payload = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        XCTAssertFalse(payload.contains("OTHER_PARAGRAPH"))
        XCTAssertFalse(payload.contains("private"))
    }

    func testLearningResponseAnchorsCannotChangeCandidate() throws {
        let original = try XCTUnwrap(proposal("This works under light-load conditions."))
        let point = LearningPoint(source: "轻载条件下", target: "different target", explanation: "bad", category: .tone)
        let response = original.explainedResponse(point)
        XCTAssertEqual(response.naturalText, original.response.naturalText)
        XCTAssertTrue(response.learningPoints.isEmpty)
        XCTAssertFalse(response.warnings.isEmpty)
    }
    func testRejectsBroaderRewriteAndMeaningChange() throws {
        XCTAssertNil(try proposal("This method works under light-load conditions."))
        XCTAssertNil(try proposal("This works under light-load conditions.", meaningPreserved: false))
    }
    func testRejectsUnchangedEmptyMultilineAndOversizedCandidate() throws {
        XCTAssertNil(try proposal(text))
        XCTAssertNil(try proposal("This works ."))
        XCTAssertNil(try proposal("This works under\nlight-load conditions."))
        XCTAssertNil(try proposal("This works " + String(repeating: "a", count: 241) + "."))
    }
    func testPreciseRangeGateRefusesChangedSourceSelectionAndFocus() throws {
        let proposal = try XCTUnwrap(proposal("This works under light-load conditions."))
        let original = proposal.snapshot
        let gate = ReplacementPreflight()
        XCTAssertNil(gate.rangeRefusal(original: original, current: original,
            range: proposal.placeholder.range, source: proposal.placeholder.text))
        for (text, selection, field, refusal) in [
            (original.text + "!", original.selectedRange, "field", ReplacementRefusal.sourceChanged),
            (original.text, NSRange(location: 0, length: 0), "field", .selectionChanged),
            (original.text, original.selectedRange, "different", .focusChanged)
        ] {
            let current = TextSnapshot(applicationIdentifier: "test", focusedElementIdentifier: field, text: text,
                selectedRange: selection, revisionToken: original.revisionToken)
            XCTAssertEqual(gate.rangeRefusal(original: original, current: current,
                range: proposal.placeholder.range, source: proposal.placeholder.text), refusal)
        }
    }
}
