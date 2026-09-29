import Foundation
import PlatformBridge
import XCTest

final class ReplacementPreflightTests: XCTestCase {
    private let source = "Write under light-load conditions."

    private func snapshot(
        app: String = "test.app",
        element: String = "source-field",
        text: String? = nil,
        range: NSRange = NSRange(location: 6, length: 27),
        revision: String = "revision-1"
    ) -> TextSnapshot {
        TextSnapshot(
            applicationIdentifier: app,
            focusedElementIdentifier: element,
            text: text ?? source,
            selectedRange: range,
            revisionToken: revision
        )
    }

    private var scope: ResolvedTextScope {
        ResolvedTextScope(
            range: NSRange(location: 6, length: 27),
            text: "under light-load conditions",
            kind: .explicitSelection
        )
    }

    func testUnchangedSourceAndFocusMayReplace() {
        let original = snapshot()
        XCTAssertNil(ReplacementPreflight().refusal(original: original, current: original, scope: scope))
    }

    func testDifferentFieldInSameAppRefuses() {
        XCTAssertEqual(
            ReplacementPreflight().refusal(
                original: snapshot(), current: snapshot(element: "other-field"), scope: scope
            ),
            .focusChanged
        )
    }

    func testDifferentAppRefuses() {
        XCTAssertEqual(
            ReplacementPreflight().refusal(
                original: snapshot(), current: snapshot(app: "other.app"), scope: scope
            ),
            .focusChanged
        )
    }

    func testEditedSourceRefusesEvenWithSameFocus() {
        XCTAssertEqual(
            ReplacementPreflight().refusal(
                original: snapshot(), current: snapshot(text: "Write new text."), scope: scope
            ),
            .sourceChanged
        )
    }

    func testRevisionChangeRefusesEvenIfTextMatches() {
        XCTAssertEqual(
            ReplacementPreflight().refusal(
                original: snapshot(), current: snapshot(revision: "revision-2"), scope: scope
            ),
            .sourceChanged
        )
    }

    func testSelectionChangeRefuses() {
        XCTAssertEqual(
            ReplacementPreflight().refusal(
                original: snapshot(),
                current: snapshot(range: NSRange(location: 0, length: 0)), scope: scope
            ),
            .selectionChanged
        )
    }

    func testMismatchedScopeRefuses() {
        let staleScope = ResolvedTextScope(
            range: scope.range,
            text: "different text",
            kind: .explicitSelection
        )
        XCTAssertEqual(
            ReplacementPreflight().refusal(original: snapshot(), current: snapshot(), scope: staleScope),
            .invalidScope
        )
    }

    func testValidTextAtDifferentRangeStillRefuses() {
        let forgedScope = ResolvedTextScope(
            range: NSRange(location: 0, length: 5),
            text: "Write",
            kind: .explicitSelection
        )
        XCTAssertEqual(
            ReplacementPreflight().refusal(
                original: snapshot(), current: snapshot(), scope: forgedScope
            ),
            .invalidScope
        )
    }

    func testMissingElementIdentityRefuses() {
        XCTAssertEqual(
            ReplacementPreflight().refusal(
                original: snapshot(), current: snapshot(element: ""), scope: scope
            ),
            .invalidCapture
        )
    }

    func testOutOfBoundsScopeRefusesWithoutOverflow() {
        let badScope = ResolvedTextScope(
            range: NSRange(location: Int.max - 1, length: 10),
            text: "anything",
            kind: .explicitSelection
        )
        XCTAssertEqual(
            ReplacementPreflight().refusal(original: snapshot(), current: snapshot(), scope: badScope),
            .invalidScope
        )
    }
}
