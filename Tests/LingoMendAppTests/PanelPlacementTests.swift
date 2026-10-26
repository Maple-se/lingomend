import AppKit
@testable import LingoMendApp
import XCTest

@MainActor
final class PanelPlacementTests: XCTestCase {
    private let primary = PanelPlacement.Display(
        frame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
        visibleFrame: NSRect(x: 0, y: 0, width: 1920, height: 1056))

    func testSecondaryDisplayToRightUsesItsVisibleFrame() {
        let secondary = PanelPlacement.Display(
            frame: NSRect(x: 1920, y: 0, width: 1440, height: 900),
            visibleFrame: NSRect(x: 1920, y: 0, width: 1440, height: 878))
        let result = PanelPlacement.frame(anchor: CGRect(x: 3000, y: 200, width: 2, height: 20),
            preferredSize: NSSize(width: 470, height: 340), fallback: .zero,
            primaryTop: 1080, displays: [primary, secondary])
        XCTAssertGreaterThanOrEqual(result.minX, secondary.visibleFrame.minX + 8)
        XCTAssertLessThanOrEqual(result.maxX, secondary.visibleFrame.maxX - 8)
        XCTAssertGreaterThanOrEqual(result.minY, secondary.visibleFrame.minY + 8)
        XCTAssertLessThanOrEqual(result.maxY, secondary.visibleFrame.maxY - 8)
    }

    func testDisplayAbovePrimaryAndTopEdgeStayVisible() {
        let upper = PanelPlacement.Display(
            frame: NSRect(x: 0, y: 1080, width: 1600, height: 900),
            visibleFrame: NSRect(x: 0, y: 1080, width: 1600, height: 876))
        let result = PanelPlacement.frame(anchor: CGRect(x: 1500, y: -850, width: 2, height: 20),
            preferredSize: NSSize(width: 470, height: 440), fallback: .zero,
            primaryTop: 1080, displays: [primary, upper])
        XCTAssertGreaterThanOrEqual(result.minY, upper.visibleFrame.minY + 8)
        XCTAssertLessThanOrEqual(result.maxY, upper.visibleFrame.maxY - 8)
        XCTAssertLessThanOrEqual(result.maxX, upper.visibleFrame.maxX - 8)
    }

    func testBottomEdgeMovesCardAboveAnchor() {
        let result = PanelPlacement.frame(anchor: CGRect(x: 100, y: 1040, width: 2, height: 20),
            preferredSize: NSSize(width: 470, height: 340), fallback: .zero,
            primaryTop: 1080, displays: [primary])
        XCTAssertGreaterThan(result.minY, 20)
        XCTAssertLessThanOrEqual(result.maxY, primary.visibleFrame.maxY - 8)
    }
}
