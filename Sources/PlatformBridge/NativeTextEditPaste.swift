import AppKit
import ApplicationServices
import Carbon

@MainActor
public protocol NativePasteDriving: AnyObject {
  var modifiersReleased: Bool { get }
  func capture() throws -> TextSnapshot
  func attributedTarget(_ range: NSRange) throws -> NSAttributedString
  func select(_ range: NSRange) throws
  func postPaste() throws
}

public struct NativePasteResult: Sendable {
  public let clipboard: ClipboardRestoration
  public let caretPositioned: Bool
}

/// Single native paste; no retries, automatic undo, document activation, or whole-field setters.
@MainActor
public final class NativeTextEditPaste {
  private let driver: any NativePasteDriving
  private let clipboard: NativeClipboardLease
  public private(set) var isBusy = false

  public init(
    driver: any NativePasteDriving, clipboard: NativeClipboardLease = NativeClipboardLease()
  ) {
    self.driver = driver
    self.clipboard = clipboard
  }

  public func accept(_ plan: SentenceEditPlan) async throws -> NativePasteResult {
    guard !isBusy else { throw NativePasteError.busy }
    isBusy = true
    defer { isBusy = false }
    try check(plan, current: driver.capture())
    let source = try driver.attributedTarget(plan.scope.target.range)
    guard source.string == plan.scope.target.text else {
      throw NativePasteError.stale(.sourceChanged)
    }
    let rich = try BasicRichText.replacement(source: source, text: plan.replacement)
      .attributedSubstring(from: plan.replacementRange)
    let rtf = try rich.data(
      from: NSRange(location: 0, length: rich.length),
      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    // The acceptance shortcut may still be physically held. Never issue Cmd-V with
    // Ctrl/Option/Shift held, and never synthesize their key-up events for the user.
    for _ in 0..<80 {
      try Task.checkCancellation()
      if driver.modifiersReleased { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    guard driver.modifiersReleased else { throw NativePasteError.modifiersHeld }
    try Task.checkCancellation()
    try check(plan, current: driver.capture())
    try clipboard.begin(rtf: rtf, text: plan.insertedText)
    var dispatched = false
    do {
      // All pre-paste operations below are synchronous on the main actor. Any mismatch
      // stops before posting an event; a second read verifies the range setter actually worked.
      try check(plan, current: driver.capture())
      guard clipboard.ownsContents, driver.modifiersReleased else {
        throw NativePasteError.clipboardChanged
      }
      try driver.select(plan.range)
      let selected = try driver.capture()
      guard sameDocument(selected, plan.original), selected.text == plan.original.text,
        selected.revisionToken == plan.original.revisionToken, selected.selectedRange == plan.range,
        clipboard.ownsContents, driver.modifiersReleased
      else { throw NativePasteError.selectionFailed }
      try driver.postPaste()
      dispatched = true

      // After dispatch, cancellation cannot roll back an external edit. Finish bounded
      // verification/clipboard cleanup and report uncertainty rather than pasting again.
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: .seconds(1.2))
      repeat {
        if let current = try? driver.capture(), sameDocument(current, plan.original),
          current.text == plan.expectedText
        {
          let nativeCaret = NSRange(
            location: plan.range.location + plan.insertedText.utf16.count, length: 0)
          var positioned = current.selectedRange == plan.caretAfter
          if current.selectedRange == nativeCaret {
            try? driver.select(plan.caretAfter)
            if let verified = try? driver.capture() {
              positioned =
                sameDocument(verified, plan.original) && verified.text == plan.expectedText
                && verified.selectedRange == plan.caretAfter
            }
          }
          return NativePasteResult(clipboard: clipboard.restore(), caretPositioned: positioned)
        }
        try? await Task.sleep(for: .milliseconds(20))
      } while clock.now < deadline
      throw NativePasteError.resultUnconfirmed
    } catch {
      if !dispatched { restoreSelectionIfUnchanged(plan) }
      if clipboard.restore() == .failed {
        throw NativePasteError.clipboardRestorationFailed(dispatched: dispatched)
      }
      throw error
    }
  }

  private func check(_ plan: SentenceEditPlan, current: TextSnapshot) throws {
    if let refusal = plan.refusal(current: current) { throw NativePasteError.stale(refusal) }
  }
  private func sameDocument(_ a: TextSnapshot, _ b: TextSnapshot) -> Bool {
    a.applicationIdentifier == b.applicationIdentifier
      && a.focusedElementIdentifier == b.focusedElementIdentifier
  }
  private func restoreSelectionIfUnchanged(_ plan: SentenceEditPlan) {
    guard let current = try? driver.capture(), sameDocument(current, plan.original),
      current.text == plan.original.text, current.selectedRange == plan.range
    else { return }
    try? driver.select(plan.original.selectedRange)
  }
}

@MainActor
public final class MacOSTextEditPasteDriver: NativePasteDriving {
  private let reader: MacOSAccessibilityTextReader
  private var element: AXUIElement?
  private var pid: pid_t = 0
  public init(reader: MacOSAccessibilityTextReader) { self.reader = reader }
  public var modifiersReleased: Bool {
    CGEventSource.flagsState(.combinedSessionState).intersection([
      .maskControl, .maskAlternate, .maskShift, .maskCommand,
    ]).isEmpty
  }
  public func capture() throws -> TextSnapshot {
    let snapshot = try reader.captureFocusedText()
    guard snapshot.applicationIdentifier == "com.apple.TextEdit",
      let focused = reader.capturedElement,
      AXUIElementGetPid(focused, &pid) == .success,
      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    else {
      throw NativePasteError.stale(.focusChanged)
    }
    element = focused
    return snapshot
  }
  public func attributedTarget(_ range: NSRange) throws -> NSAttributedString {
    guard let element else { throw NativePasteError.formatUnavailable }
    var range = CFRange(location: range.location, length: range.length)
    guard let argument = AXValueCreate(.cfRange, &range) else {
      throw NativePasteError.formatUnavailable
    }
    var value: CFTypeRef?
    guard
      AXUIElementCopyParameterizedAttributeValue(
        element, kAXAttributedStringForRangeParameterizedAttribute as CFString,
        argument, &value) == .success,
      let result = value as? NSAttributedString, result.length == range.length
    else {
      throw NativePasteError.formatUnavailable
    }
    return result
  }
  public func select(_ range: NSRange) throws {
    guard let element else { throw NativePasteError.selectionFailed }
    var settable = DarwinBoolean(false)
    guard
      AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &settable)
        == .success,
      settable.boolValue
    else { throw NativePasteError.selectionFailed }
    var range = CFRange(location: range.location, length: range.length)
    guard let value = AXValueCreate(.cfRange, &range),
      AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
        == .success
    else {
      throw NativePasteError.selectionFailed
    }
  }
  public func postPaste() throws {
    guard pid > 0, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
      modifiersReleased,
      let source = CGEventSource(stateID: .privateState),
      let down = CGEvent(
        keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
      let up = CGEvent(
        keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
    else {
      throw NativePasteError.eventUnavailable
    }
    down.flags = .maskCommand
    up.flags = .maskCommand
    down.postToPid(pid)
    up.postToPid(pid)
  }
}
