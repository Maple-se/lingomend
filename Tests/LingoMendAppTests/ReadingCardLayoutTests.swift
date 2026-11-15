import AppKit
@testable import LingoMendApp
import XCTest

@MainActor
final class ReadingCardLayoutTests: XCTestCase {
    func testHeaderAndControlBoundsMatchPhaseOneContract() {
        XCTAssertEqual(ReadingCardLayout.baseHeaderHeight, 56)
        XCTAssertEqual(ReadingCardLayout.maximumHeaderHeight, 64)
        XCTAssertEqual(ReadingCardLayout.minimumControlHeight, 44)
        XCTAssertGreaterThanOrEqual(ReadingCardLayout.headerHeight, ReadingCardLayout.baseHeaderHeight)
        XCTAssertLessThanOrEqual(ReadingCardLayout.headerHeight, ReadingCardLayout.maximumHeaderHeight)
    }

    func testPanelStartsHiddenAndHideReturnsToHidden() {
        let panel = ReadingPanel()
        XCTAssertEqual(panel.state, .hidden)
        panel.hide()
        XCTAssertEqual(panel.state, .hidden)
    }
}
