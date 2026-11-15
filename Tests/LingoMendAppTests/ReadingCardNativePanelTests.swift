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
        XCTAssertTrue(surface.show(request: request, explanation: explanation,
            anchor: CGRect(x: 120, y: screen.frame.height - 200, width: 80, height: 20),
            onDismiss: { }, onOutsideClick: { }, onPinChanged: { _ in }))
        guard let window = NSApplication.shared.windows.first(where: { $0.isVisible }) else {
            XCTFail("Reading panel window was not created")
            return
        }
        surface.togglePin()
        XCTAssertTrue(surface.isPinned)
        XCTAssertEqual(surface.state, .pinned)
        XCTAssertTrue(window.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenAuxiliary))
        let pinnedFrame = window.frame
        let fullScreenSelection = CGRect(x: screen.frame.minX, y: 0,
            width: screen.frame.width, height: screen.frame.height)
        XCTAssertFalse(surface.show(request: request, explanation: explanation,
            anchor: fullScreenSelection, onDismiss: { }, onOutsideClick: { }, onPinChanged: { _ in }))
        XCTAssertTrue(surface.isPinned)
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(window.frame, pinnedFrame)
        surface.togglePin()
        XCTAssertFalse(surface.isPinned)
        XCTAssertEqual(surface.state, .shownManually)
        XCTAssertTrue(window.collectionBehavior.contains(.moveToActiveSpace))
    }

    func testWindowKeepsCompactFrameOutsideSelection() async throws {
        guard ProcessInfo.processInfo.environment["LINGOMEND_NATIVE_PANEL_TESTS"] == "1" else {
            throw XCTSkip("Enable LINGOMEND_NATIVE_PANEL_TESTS in a graphical session")
        }
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let area = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        guard area.height > 434, area.width >= 460 else { throw XCTSkip("Display is too small for this fixture") }

        let selection = area.insetBy(dx: 0, dy: 217)
        let anchor = CGRect(x: selection.minX, y: screen.frame.maxY - selection.maxY,
            width: selection.width, height: selection.height)
        let request = try ReadingRequest(selection: "current", before: "The ", after: " flows.",
            contextKind: .sentence)
        let explanation = ReadingExplanation(meaning: "电流", contextMeaning: "电流流动。",
            usage: String(repeating: "合成测试。", count: 55))
        let surface = ReadingPanel()
        defer { surface.hide() }
        XCTAssertTrue(surface.show(request: request, explanation: explanation,
            anchor: anchor, onDismiss: { }, onOutsideClick: { }, onPinChanged: { _ in }))
        let window = try XCTUnwrap(NSApplication.shared.windows.first(where: { $0.isVisible }))
        XCTAssertEqual(window.frame.height, 205, accuracy: 1)
        XCTAssertTrue(area.contains(window.frame))
        XCTAssertFalse(window.frame.intersects(selection.insetBy(dx: -12, dy: -12)))
    }
}
