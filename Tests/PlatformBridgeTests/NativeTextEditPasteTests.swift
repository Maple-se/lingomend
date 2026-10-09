import AppKit
import PlatformBridge
import XCTest

@MainActor
private final class UndoTextView: NSTextView {
  let localUndo = UndoManager()
  override var undoManager: UndoManager? { localUndo }
}

/// A hidden in-process editor and named test clipboard; never TextEdit or the general clipboard.
@MainActor
private final class TestPasteDriver: NativePasteDriving {
  let view = UndoTextView(frame: .zero)
  let board: NSPasteboard
  var modifiersReleased = true
  var field = "synthetic-field"
  var captures = 0, pastes = 0
  var onCapture: ((Int) -> Void)?
  var beforePaste: (() -> Void)?
  var ignorePaste = false
  var selectionFails = false
  var refuseEvent = false
  var formatFails = false
  init(board: NSPasteboard, text: String) {
    self.board = board
    view.isRichText = true
    view.allowsUndo = true
    view.textStorage?.setAttributedString(
      NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14)]))
    view.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
    view.localUndo.removeAllActions()
  }
  func capture() throws -> TextSnapshot {
    captures += 1
    onCapture?(captures)
    return TextSnapshot(
      applicationIdentifier: "com.apple.TextEdit", focusedElementIdentifier: field,
      text: view.string, selectedRange: view.selectedRange(), revisionToken: view.string)
  }
  func attributedTarget(_ range: NSRange) throws -> NSAttributedString {
    if formatFails { throw NativePasteError.formatUnavailable }
    return view.textStorage!.attributedSubstring(from: range)
  }
  func select(_ range: NSRange) throws {
    if selectionFails { throw NativePasteError.selectionFailed }
    view.setSelectedRange(range)
  }
  func postPaste() throws {
    if refuseEvent { throw NativePasteError.eventUnavailable }
    pastes += 1
    if !ignorePaste { _ = view.readSelection(from: board) }
    beforePaste?()
  }
}

final class NativeTextEditPasteTests: XCTestCase {
  @MainActor private func fixture(
    _ text: String = "First stays. This works 轻载条件下.",
    replacement: String = "This works under light-load conditions."
  ) throws
    -> (NSPasteboard, TestPasteDriver, NativeTextEditPaste, SentenceEditPlan)
  {
    let board = NSPasteboard(name: NSPasteboard.Name("lingomend-transaction-test-\(UUID())"))
    board.clearContents()
    board.setString("CLIPBOARD_BEFORE", forType: .string)
    let driver = TestPasteDriver(board: board, text: text)
    let original = try driver.capture()
    let plan = try SentenceEditPlan(
      original: original, scope: SentenceScopeResolver().resolve(original), replacement: replacement
    )
    return (
      board, driver,
      NativeTextEditPaste(driver: driver, clipboard: NativeClipboardLease(board: board)), plan
    )
  }
  @MainActor func testOneNativeEditorPasteAndOneUndoWithOutsideTextUntouched() async throws {
    let (board, driver, writer, plan) = try fixture()
    defer { board.releaseGlobally() }
    let result = try await writer.accept(plan)
    XCTAssertEqual(driver.pastes, 1)
    XCTAssertEqual(driver.view.string, plan.expectedText)
    XCTAssertTrue(result.caretPositioned)
    XCTAssertEqual(driver.view.selectedRange(), plan.caretAfter)
    XCTAssertEqual(result.clipboard, .restored)
    XCTAssertEqual(board.string(forType: .string), "CLIPBOARD_BEFORE")
    XCTAssertTrue(driver.view.localUndo.canUndo)
    driver.view.localUndo.undo()
    XCTAssertEqual(driver.view.string, plan.original.text)
    XCTAssertFalse(driver.view.localUndo.canUndo)
  }
  @MainActor func testNativePasteAndUndoPreserveBoldAndUnderline() async throws {
    let (board, driver, _, _) = try fixture(
      "We need 降低损耗 without 增加成本.", replacement: "We need reduce losses without increasing costs.")
    defer { board.releaseGlobally() }
    let text = driver.view.string as NSString
    driver.view.textStorage!.addAttribute(
      .font, value: NSFont.boldSystemFont(ofSize: 20), range: text.range(of: "降低损耗"))
    driver.view.textStorage!.addAttribute(
      .underlineStyle, value: 1, range: text.range(of: "without"))
    let originalRich = NSAttributedString(attributedString: driver.view.textStorage!)
    let original = try driver.capture()
    let plan = try SentenceEditPlan(
      original: original,
      scope: SentenceScopeResolver().resolve(original),
      replacement: "We need reduce losses without increasing costs.")
    _ = try await NativeTextEditPaste(driver: driver, clipboard: NativeClipboardLease(board: board))
      .accept(plan)
    let result = driver.view.textStorage!
    let bold = (result.string as NSString).range(of: "reduce").location
    XCTAssertEqual(
      (result.attribute(.font, at: bold, effectiveRange: nil) as? NSFont)?.pointSize, 20)
    XCTAssertEqual(
      result.attribute(
        .underlineStyle, at: (result.string as NSString).range(of: "without").location,
        effectiveRange: nil) as? NSNumber, 1)
    driver.view.localUndo.undo()
    XCTAssertTrue(driver.view.textStorage!.isEqual(to: originalRich))
  }
  @MainActor func testStaleBeforeAcceptanceDoesNotTouchClipboardOrPaste() async throws {
    let (board, driver, writer, plan) = try fixture()
    defer { board.releaseGlobally() }
    driver.field = "different-document"
    let count = board.changeCount
    do {
      _ = try await writer.accept(plan)
      XCTFail("Expected refusal")
    } catch { XCTAssertEqual(error as? NativePasteError, .stale(.focusChanged)) }
    XCTAssertEqual(driver.pastes, 0)
    XCTAssertEqual(board.changeCount, count)
  }
  @MainActor func testFinalCaptureChangeRefusesAndRestoresClipboard() async throws {
    let (board, driver, writer, plan) = try fixture()
    defer { board.releaseGlobally() }
    driver.onCapture = { count in if count == 4 { driver.field = "different-document" } }
    do {
      _ = try await writer.accept(plan)
      XCTFail("Expected refusal")
    } catch {}
    XCTAssertEqual(driver.pastes, 0)
    XCTAssertEqual(board.string(forType: .string), "CLIPBOARD_BEFORE")
  }
  @MainActor func testChangedSelectionAfterRangeSetterDoesNotPaste() async throws {
    let (board, driver, writer, plan) = try fixture()
    defer { board.releaseGlobally() }
    driver.onCapture = { count in
      if count == 5 { driver.view.setSelectedRange(NSRange(location: 0, length: 0)) }
    }
    do {
      _ = try await writer.accept(plan)
      XCTFail("Expected refusal")
    } catch {}
    XCTAssertEqual(driver.pastes, 0)
    XCTAssertEqual(driver.view.string, plan.original.text)
    XCTAssertEqual(driver.view.selectedRange(), NSRange(location: 0, length: 0))
    XCTAssertEqual(board.string(forType: .string), "CLIPBOARD_BEFORE")
  }
  @MainActor func testEventFailureRestoresOriginalSelectionAndClipboard() async throws {
    let (board, driver, writer, plan) = try fixture()
    defer { board.releaseGlobally() }
    driver.refuseEvent = true
    do {
      _ = try await writer.accept(plan)
      XCTFail("Expected refusal")
    } catch {}
    XCTAssertEqual(driver.pastes, 0)
    XCTAssertEqual(driver.view.selectedRange(), plan.original.selectedRange)
    XCTAssertEqual(board.string(forType: .string), "CLIPBOARD_BEFORE")
  }
  @MainActor func testConcurrentCopyBeforePasteStopsWithoutOverwritingNewCopy() async throws {
    let (board, driver, writer, plan) = try fixture()
    defer { board.releaseGlobally() }
    driver.onCapture = { count in
      if count == 5 {
        board.clearContents()
        board.setString("NEW_COPY", forType: .string)
      }
    }
    do {
      _ = try await writer.accept(plan)
      XCTFail("Expected refusal")
    } catch {}
    XCTAssertEqual(driver.pastes, 0)
    XCTAssertEqual(board.string(forType: .string), "NEW_COPY")
  }
  @MainActor func testCopyAfterPasteIsKeptAndNotReportedAsRestoreFailure() async throws {
    let (board, driver, writer, plan) = try fixture()
    defer { board.releaseGlobally() }
    driver.beforePaste = {
      board.clearContents()
      board.setString("NEW_COPY", forType: .string)
    }
    let result = try await writer.accept(plan)
    XCTAssertEqual(driver.pastes, 1)
    XCTAssertEqual(result.clipboard, .changedExternally)
    XCTAssertEqual(board.string(forType: .string), "NEW_COPY")
  }
  @MainActor func testNoDeliveryTimesOutWithoutRetryAndRestoresClipboard() async throws {
    let (board, driver, writer, plan) = try fixture()
    defer { board.releaseGlobally() }
    driver.ignorePaste = true
    do {
      _ = try await writer.accept(plan)
      XCTFail("Expected uncertain result")
    } catch { XCTAssertEqual(error as? NativePasteError, .resultUnconfirmed) }
    XCTAssertEqual(driver.pastes, 1)
    XCTAssertEqual(board.string(forType: .string), "CLIPBOARD_BEFORE")
  }
  @MainActor func testCancelWhileWaitingForModifiersDoesNotTouchClipboard() async throws {
    let (board, driver, writer, plan) = try fixture()
    defer { board.releaseGlobally() }
    driver.modifiersReleased = false
    let count = board.changeCount
    let task = Task { try await writer.accept(plan) }
    try await Task.sleep(for: .milliseconds(20))
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(driver.pastes, 0)
    XCTAssertEqual(board.changeCount, count)
  }
  @MainActor func testSecondAcceptanceIsRejectedWhileFirstWaits() async throws {
    let (board, driver, writer, plan) = try fixture()
    defer { board.releaseGlobally() }
    driver.modifiersReleased = false
    let task = Task { try await writer.accept(plan) }
    try await Task.sleep(for: .milliseconds(20))
    do {
      _ = try await writer.accept(plan)
      XCTFail("Expected busy")
    } catch { XCTAssertEqual(error as? NativePasteError, .busy) }
    task.cancel()
    _ = try? await task.value
    XCTAssertEqual(driver.pastes, 0)
  }
  @MainActor func testUnavailableFormatStopsBeforeClipboardBorrow() async throws {
    let (board, driver, writer, plan) = try fixture()
    defer { board.releaseGlobally() }
    driver.formatFails = true
    let count = board.changeCount
    do {
      _ = try await writer.accept(plan)
      XCTFail("Expected refusal")
    } catch { XCTAssertEqual(error as? NativePasteError, .formatUnavailable) }
    XCTAssertEqual(board.changeCount, count)
    XCTAssertEqual(driver.pastes, 0)
  }
}
