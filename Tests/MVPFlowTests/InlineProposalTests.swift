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
