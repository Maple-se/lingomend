import AppKit
import CoachCore
@testable import LingoMendApp
import MVPFlow
import PlatformBridge
import XCTest

/// Explicitly enabled, isolated panel test. Does not read or edit another app,
/// use the clipboard, invoke a provider, or simulate user input.
@MainActor
final class WritingCardNativePanelTests: XCTestCase {
    func testLifecycleReusesWindowAndHostingViewWithoutActivatingEditorFocus() async throws {
        guard ProcessInfo.processInfo.environment["LINGOMEND_NATIVE_PANEL_TESTS"] == "1" else {
            throw XCTSkip("Enable LINGOMEND_NATIVE_PANEL_TESTS in a graphical session")
        }
        _ = NSApplication.shared
        guard let screen = NSScreen.screens.first else { throw XCTSkip("No display available") }
        // Exercise growth below the text and above text near the display bottom.
        for y in [CGFloat(160), screen.frame.height - 70] {
            try await verifyLifecycle(anchor: CGRect(x: screen.frame.minX + 100,
                y: y, width: 2, height: 20))
        }
    }

    private func verifyLifecycle(anchor: CGRect) async throws {
        let app = NSApplication.shared
        let previousWindows = Set(app.windows.map(ObjectIdentifier.init))
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let surface = SentenceCandidatePanel()
        defer { surface.hide() }
        surface.start(anchor: anchor, onDismiss: { })
        let window = try XCTUnwrap(app.windows.first { !previousWindows.contains(ObjectIdentifier($0)) })
        let content = try XCTUnwrap(window.contentView)
        let compact = window.frame
        XCTAssertEqual(compact.height, 120, accuracy: 1)
        XCTAssertFalse(window.canBecomeKey)
        XCTAssertFalse(window.canBecomeMain)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertFalse(window.isMainWindow)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, frontmost)

        let text = "I very like 这个方案."
        let snapshot = TextSnapshot(applicationIdentifier: "com.apple.TextEdit",
            focusedElementIdentifier: "synthetic-editor", text: text,
            selectedRange: NSRange(location: 3, length: 0), revisionToken: "1")
        let proposal = try SentenceProposal(snapshot: snapshot,
            scope: WritingScopeResolver().resolve(snapshot),
            advice: SentenceAdvice(status: .suggest, replacement: "I really like this approach."))
        surface.show(proposal, onAccept: { }, onExplain: { nil })
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(window.contentView === content)
        XCTAssertEqual(window.frame.height, 400, accuracy: 1)
        XCTAssertEqual(app.windows.filter { !previousWindows.contains(ObjectIdentifier($0)) }.count, 1)
        XCTAssertEqual(window.frame.minX, compact.minX, accuracy: 1)
        XCTAssertTrue(abs(window.frame.minY - compact.minY) < 1
            || abs(window.frame.maxY - compact.maxY) < 1)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, frontmost)

        XCTAssertTrue(surface.beginAcceptance())
        surface.completeAcceptance(message: "已接受 · 以普通文本写入，格式未保证；在原编辑器按 ⌘Z 可撤销")
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(window.contentView === content)
        XCTAssertEqual(window.frame.height, 120, accuracy: 1,
            "The outgoing candidate must not keep the acceptance card expanded")
        XCTAssertEqual(content.bounds.height, window.contentLayoutRect.height, accuracy: 1,
            "The hosting view must track the actual compact window size")
        XCTAssertTrue(abs(window.frame.minY - compact.minY) < 1
            || abs(window.frame.maxY - compact.maxY) < 1,
            "The success card must keep its original text attachment edge")
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, frontmost)
        surface.hide()
        XCTAssertFalse(window.isVisible)
    }
}
