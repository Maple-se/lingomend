import AppKit
import ApplicationServices
import Carbon
import DiagnosticsCore

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
  private let diagnostics: any DiagnosticRecording
  public private(set) var isBusy = false

  public init(
    driver: any NativePasteDriving, clipboard: NativeClipboardLease = NativeClipboardLease(),
    diagnostics: any DiagnosticRecording = NoOpDiagnostics()
  ) {
    self.driver = driver
    self.clipboard = clipboard
    self.diagnostics = diagnostics
  }

  public func accept(_ plan: SentenceEditPlan, operation: UUID? = nil) async throws -> NativePasteResult {
    let start = ContinuousClock.now
    var progress = AcceptanceProgress()
    diagnostics.record(DiagnosticEvent(.acceptanceStarted, length: plan.scope.target.text.utf16.count), operation: operation)
    do {
      let result = try await perform(plan, operation: operation, progress: &progress)
      diagnostics.record(DiagnosticEvent(.acceptanceCompleted,
        level: result.clipboard == .failed || !result.caretPositioned ? .warning : .info,
        outcome: result.clipboard == .failed || !result.caretPositioned ? .warning : .success,
        durationMS: diagnosticMilliseconds(since: start), dispatched: true), operation: operation)
      return result
    } catch {
      diagnostics.record(DiagnosticEvent(.acceptanceFailed, level: error is CancellationError ? .info : .error,
        outcome: progress.dispatched ? .unconfirmed : (error is CancellationError ? .cancelled : .refused),
        reason: pasteDiagnosticReason(error), stage: progress.stage,
        durationMS: diagnosticMilliseconds(since: start), dispatched: progress.dispatched), operation: operation)
      throw error
    }
  }

  private struct AcceptanceProgress { var stage: DiagnosticStage = .preflight; var dispatched = false }

  private func perform(_ plan: SentenceEditPlan, operation: UUID?, progress: inout AcceptanceProgress) async throws -> NativePasteResult {
    guard !isBusy else { throw NativePasteError.busy }
    isBusy = true
    defer { isBusy = false }
    try check(plan, current: driver.capture())
    diagnostics.record(DiagnosticEvent(.preflightPassed, stage: .preflight), operation: operation)
    progress.stage = .format
    let source = try driver.attributedTarget(plan.scope.target.range)
    guard source.string == plan.scope.target.text else {
      throw NativePasteError.stale(.sourceChanged)
    }
    let rich = try BasicRichText.replacement(source: source, text: plan.replacement)
      .attributedSubstring(from: plan.replacementRange)
    let rtf = try rich.data(
      from: NSRange(location: 0, length: rich.length),
      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    diagnostics.record(DiagnosticEvent(.formatPrepared, stage: .format), operation: operation)
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
    progress.stage = .clipboard
    try clipboard.begin(rtf: rtf, text: plan.insertedText)
    diagnostics.record(DiagnosticEvent(.clipboardBorrowed, stage: .clipboard), operation: operation)
    var dispatched = false
    do {
      // All pre-paste operations below are synchronous on the main actor. Any mismatch
      // stops before posting an event; a second read verifies the range setter actually worked.
      try check(plan, current: driver.capture())
      guard clipboard.ownsContents, driver.modifiersReleased else {
        throw NativePasteError.clipboardChanged
      }
      progress.stage = .selection
      try driver.select(plan.range)
      let selected = try driver.capture()
      guard sameDocument(selected, plan.original), selected.text == plan.original.text,
        selected.revisionToken == plan.original.revisionToken, selected.selectedRange == plan.range,
        clipboard.ownsContents, driver.modifiersReleased
      else { throw NativePasteError.selectionFailed }
      progress.stage = .dispatch
      try driver.postPaste()
      dispatched = true
      progress.dispatched = true
      diagnostics.record(DiagnosticEvent(.pasteDispatched, stage: .dispatch, dispatched: true), operation: operation)
      progress.stage = .verification

      // After dispatch, cancellation cannot roll back an external edit. Finish bounded
      // verification/clipboard cleanup and report uncertainty rather than pasting again.
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: .seconds(1.2))
      repeat {
        if let current = try? driver.capture(), sameDocument(current, plan.original),
          current.text == plan.expectedText
        {
          diagnostics.record(DiagnosticEvent(.pasteVerified, outcome: .success, stage: .verification), operation: operation)
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
          diagnostics.record(DiagnosticEvent(.caretChecked, outcome: positioned ? .success : .warning), operation: operation)
          progress.stage = .cleanup
          return NativePasteResult(clipboard: restoreClipboard(operation: operation), caretPositioned: positioned)
        }
        try? await Task.sleep(for: .milliseconds(20))
      } while clock.now < deadline
      throw NativePasteError.resultUnconfirmed
    } catch {
      if !dispatched { restoreSelectionIfUnchanged(plan) }
      if restoreClipboard(operation: operation) == .failed {
        throw NativePasteError.clipboardRestorationFailed(dispatched: dispatched)
      }
      throw error
    }
  }

  private func restoreClipboard(operation: UUID?) -> ClipboardRestoration {
    let result = clipboard.restore()
    let outcome: DiagnosticOutcome = switch result {
    case .restored: .restored; case .changedExternally: .superseded; case .failed: .failed
    }
    diagnostics.record(DiagnosticEvent(.clipboardRestored, level: result == .failed ? .warning : .info,
      outcome: outcome, stage: .cleanup), operation: operation)
    return result
  }

  private func pasteDiagnosticReason(_ error: Error) -> DiagnosticReason {
    if error is CancellationError { return .userCancelled }
    if case AccessibilityCaptureError.permissionRequired = error { return .permissionRequired }
    guard let error = error as? NativePasteError else { return .unknown }
    switch error {
    case .busy: return .busy
    case .stale: return .stale
    case .formatUnavailable: return .formatUnavailable
    case .unsupportedFormat: return .unsupportedFormat
    case .clipboardUnavailable: return .clipboardUnavailable
    case .clipboardChanged: return .clipboardChanged
    case .modifiersHeld: return .modifiersHeld
    case .selectionFailed: return .selectionFailed
    case .eventUnavailable: return .eventUnavailable
    case .resultUnconfirmed: return .resultUnconfirmed
    case .clipboardRestorationFailed: return .clipboardRestorationFailed
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
