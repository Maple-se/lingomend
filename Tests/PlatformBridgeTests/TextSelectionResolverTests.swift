import Foundation
import ApplicationServices
@testable import PlatformBridge
import XCTest

final class TextSelectionResolverTests: XCTestCase {
    private let resolver = TextSelectionResolver()
    func testStandardSelectionAndCaret() throws {
        let selected = NSRange(location: 12, length: 7)
        XCTAssertEqual(try resolver.resolve(singular: selected, plural: nil), selected)
        XCTAssertEqual(try resolver.resolve(singular: selected, plural: [selected]), selected)
        XCTAssertEqual(try resolver.resolve(singular: NSRange(location: 12, length: 0), plural: []), NSRange(location: 12, length: 0))
        XCTAssertNil(try resolver.resolve(singular: nil, plural: nil))
    }
    func testPluralOnlySingleSelectionDoesNotLoseContextCoordinates() throws {
        let selected = NSRange(location: 37, length: 7)
        XCTAssertEqual(try resolver.resolve(singular: nil, plural: [selected]), selected)
        let text = "The current flows through a coil. Our current plan works."
        let actual = (text as NSString).range(of: "current", options: .backwards)
        let range = try XCTUnwrap(resolver.resolve(singular: nil, plural: [actual]))
        let scope = try ReadingScopeResolver().resolve(text: text, selection: range)
        XCTAssertEqual(scope.context, "Our current plan works.")
    }
    func testMultipleCursorsAndDisjointOrAdjacentSelectionsAreRefused() {
        for plural in [[NSRange(location: 1, length: 0), NSRange(location: 8, length: 0)],
                       [NSRange(location: 1, length: 2), NSRange(location: 8, length: 2)],
                       [NSRange(location: 1, length: 2), NSRange(location: 3, length: 2)]] {
            XCTAssertThrowsError(try resolver.resolve(singular: plural[0], plural: plural)) { error in
                XCTAssertEqual(error as? AccessibilityCaptureError, .disjointSelection)
            }
        }
    }
    func testConflictingRangeMetadataAndInvalidRangesAreRejected() {
        XCTAssertThrowsError(try resolver.resolve(singular: NSRange(location: 0, length: 3),
            plural: [NSRange(location: 5, length: 3)])) { error in
            XCTAssertEqual(error as? AccessibilityCaptureError, .invalidSelection)
        }
        for range in [NSRange(location: NSNotFound, length: 1), NSRange(location: -1, length: 1),
                      NSRange(location: 1, length: -1), NSRange(location: Int.max - 1, length: 3)] {
            XCTAssertThrowsError(try resolver.resolve(singular: range, plural: nil))
        }
    }
    func testActualAXRangeArrayDecodesWithoutASingularAttribute() throws {
        var range = CFRange(location: 37, length: 7)
        let value = try XCTUnwrap(AXValueCreate(.cfRange, &range))
        XCTAssertEqual(try AXSelectionRange.decodeValues(singular: nil, plural: [value] as CFArray),
                       NSRange(location: 37, length: 7))
        XCTAssertThrowsError(try AXSelectionRange.decodeValues(singular: value, plural: [value, value] as CFArray)) { error in
            XCTAssertEqual(error as? AccessibilityCaptureError, .disjointSelection)
        }
        XCTAssertThrowsError(try AXSelectionRange.decodeValues(singular: nil, plural: "invalid array" as CFString))
        XCTAssertThrowsError(try AXSelectionRange.decodeValues(singular: nil, plural: ["not a range"] as CFArray))
    }
}
