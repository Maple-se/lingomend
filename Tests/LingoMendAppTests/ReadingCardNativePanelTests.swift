import AppKit
import CoachCore
@testable import LingoMendApp
import XCTest

@MainActor
final class ReadingCardNativePanelTests: XCTestCase {
    func testPinTogglesWindowScopeAndRestoresNormalScope() async throws {
        guard ProcessInfo.processInfo.environment["LINGOMEND_NATIVE_PANEL_TESTS"] == "1" else {
            throw XCTSkip("Enable LINGOMEND_NATIVE_PANEL_TESTS in a graphical session")
        }
        _ = NSApplication.shared
        guard let screen = NSScreen.screens.first else { throw XCTSkip("No display available") }
        let request = try ReadingRequest(selection: "current", before: "The ", after: " flows.",
            contextKind: .sentence)
        let explanation = ReadingExplanation(meaning: "当前的；电流",
            contextMeaning: "电流流动。", usage: "合成测试")
        let surface = ReadingPanel()
        defer { surface.hide() }
        surface.show(request: request, explanation: explanation,
            anchor: CGRect(x: 120, y: screen.frame.height - 200, width: 80, height: 20),
            onDismiss: { }, onOutsideClick: { }, onPinChanged: { _ in })
        guard let window = NSApplication.shared.windows.first(where: { $0.isVisible }) else {
            XCTFail("Reading panel window was not created")
            return
        }
        surface.togglePin()
        XCTAssertTrue(surface.isPinned)
        XCTAssertEqual(surface.state, .pinned)
        XCTAssertTrue(window.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenAuxiliary))
        surface.togglePin()
        XCTAssertFalse(surface.isPinned)
        XCTAssertEqual(surface.state, .shownManually)
        XCTAssertTrue(window.collectionBehavior.contains(.moveToActiveSpace))
    }
}
