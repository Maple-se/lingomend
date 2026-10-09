import AppKit
import PlatformBridge
import XCTest

final class NativeClipboardLeaseTests: XCTestCase {
  @MainActor private func board() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("lingomend-test-\(UUID())"))
  }
  @MainActor func testMultipleItemsAndTypesRestoredAndLeaseReusable() async throws {
    let board = board()
    defer { board.releaseGlobally() }
    let a = NSPasteboardItem()
    let b = NSPasteboardItem()
    let custom = NSPasteboard.PasteboardType("synthetic.custom")
    a.setString("BEFORE", forType: .string)
    a.setData(Data([1, 2, 3]), forType: custom)
    b.setString("SECOND", forType: .string)
    board.clearContents()
    XCTAssertTrue(board.writeObjects([a, b]))
    let lease = NativeClipboardLease(board: board)
    for _ in 0..<2 {
      try lease.begin(rtf: Data("SYNTHETIC_RTF".utf8), text: "SUGGESTION")
      XCTAssertTrue(lease.ownsContents)
      XCTAssertEqual(board.string(forType: .string), "SUGGESTION")
      XCTAssertEqual(lease.restore(), .restored)
      XCTAssertEqual(board.pasteboardItems?.count, 2)
      XCTAssertEqual(board.pasteboardItems?.first?.data(forType: custom), Data([1, 2, 3]))
      XCTAssertEqual(board.pasteboardItems?.last?.string(forType: .string), "SECOND")
    }
  }
  @MainActor func testExternalCopyIsNotOverwritten() async throws {
    let board = board()
    defer { board.releaseGlobally() }
    board.clearContents()
    board.setString("BEFORE", forType: .string)
    let lease = NativeClipboardLease(board: board)
    try lease.begin(rtf: Data(), text: "SUGGESTION")
    board.clearContents()
    board.setString("NEW_COPY", forType: .string)
    XCTAssertFalse(lease.ownsContents)
    XCTAssertEqual(lease.restore(), .changedExternally)
    XCTAssertEqual(board.string(forType: .string), "NEW_COPY")
  }
  @MainActor func testEmptyClipboardRestoredAndNestedBeginRefused() async throws {
    let board = board()
    defer { board.releaseGlobally() }
    board.clearContents()
    let lease = NativeClipboardLease(board: board)
    try lease.begin(rtf: Data(), text: "SUGGESTION")
    XCTAssertThrowsError(try lease.begin(rtf: Data(), text: "SECOND"))
    XCTAssertEqual(lease.restore(), .restored)
    XCTAssertTrue((board.types ?? []).isEmpty)
  }
  @MainActor func testLargeDataAndFilePromisesAreRejectedBeforeClearing() async throws {
    let board = board()
    defer { board.releaseGlobally() }
    for (type, data) in [
      (NSPasteboard.PasteboardType("synthetic.large"), Data(repeating: 7, count: 4_194_305)),
      (NSPasteboard.PasteboardType("com.apple.filepromise"), Data("PROMISE".utf8)),
    ] {
      board.clearContents()
      board.setData(data, forType: type)
      let count = board.changeCount
      XCTAssertThrowsError(
        try NativeClipboardLease(board: board).begin(rtf: Data(), text: "SUGGESTION"))
      XCTAssertEqual(board.changeCount, count)
      XCTAssertEqual(board.data(forType: type), data)
    }
  }
}
