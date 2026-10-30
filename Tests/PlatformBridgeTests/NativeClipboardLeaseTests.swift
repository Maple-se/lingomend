import AppKit
import PlatformBridge
import DiagnosticsCore
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
    for (type, data, reason) in [
      (NSPasteboard.PasteboardType("synthetic.large"), Data(repeating: 7, count: 4_194_305), ClipboardDiagnostic.Reason.byteLimit),
      (NSPasteboard.PasteboardType("com.apple.filepromise"), Data("PROMISE".utf8), .promisedData),
    ] {
      board.clearContents()
      board.setData(data, forType: type)
      let count = board.changeCount
      let lease = NativeClipboardLease(board: board)
      XCTAssertThrowsError(try lease.begin(rtf: Data(), text: "SUGGESTION"))
      XCTAssertEqual(lease.rejection?.reason, reason)
      XCTAssertEqual(board.changeCount, count)
      XCTAssertEqual(board.data(forType: type), data)
    }
  }
  @MainActor func testItemAndTypeLimitsAreDistinctAndRefusalDoesNotClearClipboard() throws {
    let board = board()
    defer { board.releaseGlobally() }
    let lease = NativeClipboardLease(board: board)
    let items = (0..<33).map { index in
      let item = NSPasteboardItem(); item.setString("SYNTHETIC_\(index)", forType: .string); return item
    }
    board.clearContents(); XCTAssertTrue(board.writeObjects(items))
    var count = board.changeCount
    XCTAssertThrowsError(try lease.begin(text: "SUGGESTION"))
    XCTAssertEqual(lease.rejection?.reason, .itemLimit); XCTAssertEqual(board.changeCount, count)
    let item = NSPasteboardItem()
    for index in 0..<65 { item.setData(Data([0]), forType: .init("synthetic.type.\(index)")) }
    board.clearContents(); XCTAssertTrue(board.writeObjects([item])); count = board.changeCount
    XCTAssertThrowsError(try lease.begin(text: "SUGGESTION"))
    XCTAssertEqual(lease.rejection?.reason, .typeLimit); XCTAssertEqual(board.changeCount, count)
    // A refusal is per-attempt; the next successful lease must not report an old cause.
    board.clearContents(); board.setString("BEFORE", forType: .string)
    try lease.begin(text: "SUGGESTION")
    XCTAssertNil(lease.rejection); XCTAssertEqual(lease.restore(), .restored)
  }
  @MainActor func testDeclaredButUnavailableDataIsRefusedWithoutDroppingTheType() throws {
    let board = board()
    defer { board.releaseGlobally() }
    let type = NSPasteboard.PasteboardType("synthetic.unavailable")
    board.declareTypes([type], owner: nil)
    let count = board.changeCount
    let lease = NativeClipboardLease(board: board)
    XCTAssertThrowsError(try lease.begin(text: "SUGGESTION"))
    XCTAssertEqual(lease.rejection?.reason, .dataUnavailable)
    XCTAssertEqual(board.changeCount, count)
    XCTAssertTrue((board.types ?? []).contains(type))
  }
}
