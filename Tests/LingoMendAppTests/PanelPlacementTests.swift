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

    func testReadingPlacementAvoidsAnchorAndPrefersBelowWhenSpaceAllows() throws {
        let anchor = CGRect(x: 700, y: 480, width: 120, height: 24)
        let result = try XCTUnwrap(PanelPlacement.readingFrame(anchor: anchor,
            preferredSize: NSSize(width: 460, height: 300), fallback: .zero,
            primaryTop: 1080, displays: [primary]))
        let anchorInAppKit = NSRect(x: anchor.minX, y: 1080 - anchor.maxY,
            width: anchor.width, height: anchor.height).insetBy(dx: -12, dy: -12)
        XCTAssertFalse(result.intersects(anchorInAppKit))
        XCTAssertLessThanOrEqual(result.maxY, anchorInAppKit.minY)
    }

    func testReadingPlacementUsesAboveWhenAnchorIsNearBottom() throws {
        let anchor = CGRect(x: 700, y: 1000, width: 120, height: 24)
        let result = try XCTUnwrap(PanelPlacement.readingFrame(anchor: anchor,
            preferredSize: NSSize(width: 460, height: 300), fallback: .zero,
            primaryTop: 1080, displays: [primary]))
        let anchorInAppKit = NSRect(x: anchor.minX, y: 1080 - anchor.maxY,
            width: anchor.width, height: anchor.height).insetBy(dx: -12, dy: -12)
        XCTAssertFalse(result.intersects(anchorInAppKit))
        XCTAssertGreaterThanOrEqual(result.minY, anchorInAppKit.maxY)
    }

    func testReadingPlacementSlidesAlongEdgeWithoutReducingSize() throws {
        let anchor = CGRect(x: 1810, y: 44, width: 80, height: 20)
        let size = NSSize(width: 460, height: 330)
        let result = try XCTUnwrap(PanelPlacement.readingFrame(anchor: anchor,
            preferredSize: size, primaryTop: 1080, displays: [primary]))
        XCTAssertEqual(result.size, size)
        XCTAssertEqual(result.maxX, primary.visibleFrame.maxX - 12)
        XCTAssertLessThanOrEqual(result.maxY, 1080 - anchor.maxY - 12)
    }

    func testReadingPlacementShrinksIntoLargerFreeStrip() throws {
        let display = PanelPlacement.Display(
            frame: NSRect(x: 0, y: 0, width: 900, height: 560),
            visibleFrame: NSRect(x: 0, y: 40, width: 900, height: 500))
        let anchor = CGRect(x: 200, y: 245, width: 500, height: 90)
        let result = try XCTUnwrap(PanelPlacement.readingFrame(anchor: anchor,
            preferredSize: NSSize(width: 460, height: 330), primaryTop: 560, displays: [display]))
        XCTAssertTrue(display.visibleFrame.insetBy(dx: 12, dy: 12).contains(result))
        XCTAssertEqual(result.width, 460)
        XCTAssertEqual(result.minY, 560 - anchor.minY + 12)
        XCTAssertEqual(result.maxY, 528)
    }

    func testReadingPlacementUsesOpenSideOfTallSelection() throws {
        let size = NSSize(width: 460, height: 330)
        let left = CGRect(x: 16, y: 50, width: 200, height: 970)
        let right = CGRect(x: 1700, y: 50, width: 200, height: 970)
        let placedRight = try XCTUnwrap(PanelPlacement.readingFrame(anchor: left,
            preferredSize: size, primaryTop: 1080, displays: [primary]))
        let placedLeft = try XCTUnwrap(PanelPlacement.readingFrame(anchor: right,
            preferredSize: size, primaryTop: 1080, displays: [primary]))
        XCTAssertEqual(placedRight.minX, left.maxX + 12)
        XCTAssertEqual(placedLeft.maxX, right.minX - 12)
    }

    func testReadingPlacementDeclinesWhenSelectionLeavesNoReadableSpace() {
        let anchor = CGRect(x: 80, y: 100, width: 1760, height: 900)
        XCTAssertNil(PanelPlacement.readingFrame(anchor: anchor,
            preferredSize: NSSize(width: 460, height: 330), primaryTop: 1080, displays: [primary]))
    }

    func testDraggedFrameClampsToVisibleFrameOfPointerDisplay() {
        let secondary = PanelPlacement.Display(
            frame: NSRect(x: 1920, y: 0, width: 1440, height: 900),
            visibleFrame: NSRect(x: 1920, y: 0, width: 1440, height: 878))
        let proposed = NSRect(x: 3200, y: -120, width: 460, height: 300)
        let result = PanelPlacement.clampedFrame(proposed,
            to: [primary, secondary], pointer: NSPoint(x: 3300, y: 20))
        XCTAssertGreaterThanOrEqual(result.minX, secondary.visibleFrame.minX + 8)
        XCTAssertLessThanOrEqual(result.maxX, secondary.visibleFrame.maxX - 8)
        XCTAssertGreaterThanOrEqual(result.minY, secondary.visibleFrame.minY + 8)
        XCTAssertLessThanOrEqual(result.maxY, secondary.visibleFrame.maxY - 8)
    }

    func testDraggedFrameFollowsPointerAcrossSeamEvenWhenMostOfCardIsOnOldDisplay() {
        let secondary = PanelPlacement.Display(
            frame: NSRect(x: 1920, y: 0, width: 900, height: 700),
            visibleFrame: NSRect(x: 1920, y: 0, width: 900, height: 676))
        let proposed = NSRect(x: 1540, y: 300, width: 460, height: 330)
        let result = PanelPlacement.clampedFrame(proposed,
            to: [primary, secondary], pointer: NSPoint(x: 1924, y: 610))
        XCTAssertTrue(secondary.visibleFrame.insetBy(dx: 12, dy: 12).contains(result))
        XCTAssertEqual(result.size, proposed.size)
    }
}
