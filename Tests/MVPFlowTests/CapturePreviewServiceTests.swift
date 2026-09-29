import CoachCore
import Foundation
import MVPFlow
import PlatformBridge
import XCTest

private struct FixedReader: FocusedTextReading {
    let snapshot: TextSnapshot

    func readFocusedText() async throws -> TextSnapshot { snapshot }
}

private actor RecordingProvider: CoachingProvider {
    private(set) var lastSource: String?

    func suggest(_ request: CoachRequest) async throws -> CoachResponse {
        lastSource = request.sourceText
        return CoachResponse(naturalText: request.sourceText, meaningPreserved: true)
    }
}

final class CapturePreviewServiceTests: XCTestCase {
    func testCaretInMultilineFieldSendsOnlyCurrentParagraph() async throws {
        let first = "First paragraph with 轻载条件下."
        let second = "Second paragraph must stay private."
        let text = "\(first)\n\(second)"
        let snapshot = TextSnapshot(
            applicationIdentifier: "test.app",
            focusedElementIdentifier: "editor",
            text: text,
            selectedRange: NSRange(location: 10, length: 0),
            revisionToken: "1"
        )
        let provider = RecordingProvider()
        let service = CapturePreviewService(reader: FixedReader(snapshot: snapshot), provider: provider)

        let session = try await service.capture()

        XCTAssertEqual(session.scope.text, first)
        let sent = await provider.lastSource
        XCTAssertEqual(sent, first)
        XCTAssertFalse(sent?.contains(second) ?? true)
    }

    func testWhitespaceOnlyFieldDoesNotCallProvider() async throws {
        let snapshot = TextSnapshot(
            applicationIdentifier: "test.app",
            focusedElementIdentifier: "editor",
            text: "   ",
            selectedRange: NSRange(location: 2, length: 0),
            revisionToken: "1"
        )
        let provider = RecordingProvider()
        let service = CapturePreviewService(reader: FixedReader(snapshot: snapshot), provider: provider)

        do {
            _ = try await service.capture()
            XCTFail("Expected no usable scope")
        } catch CapturePreviewError.noUsableScope {
            let sent = await provider.lastSource
            XCTAssertNil(sent)
        }
    }
}
