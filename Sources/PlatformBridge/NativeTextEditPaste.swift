import AppKit
@preconcurrency import ApplicationServices
import Carbon
import DiagnosticsCore

@MainActor
public protocol NativePasteDriving: AnyObject {
  var modifiersReleased: Bool { get }
  func capture() throws -> TextSnapshot
  func attributedTarget(_ range: NSRange) throws -> NSAttributedString
  func preparePaste(_ plan: SentenceEditPlan) throws -> NativePastePayload
  func select(_ range: NSRange) throws
  func postPaste() throws
}

public struct NativePastePayload: Sendable {
  public let rtf: Data?
  public let preservesFormatting: Bool
  public init(rtf: Data? = nil) {
    self.rtf = rtf
    self.preservesFormatting = rtf != nil
  }
}

/// Native editors can attach private attributes to ordinary body text. Refuse
/// recognized structural content before falling back to a text-only native paste.
@MainActor
enum NativePlainTextFallback {
  static func permits(_ source: NSAttributedString, affected: NSRange) -> Bool {
    guard source.length > 0, affected.location >= 0, affected.length >= 0,
      affected.location <= source.length,
      affected.length <= source.length - affected.location,
      !source.string.contains("\u{FFFC}") else { return false }
    let inspected = affected.length > 0 ? affected
      : NSRange(location: min(affected.location, max(0, source.length - 1)), length: min(1, source.length))
    var permitted = true
    source.enumerateAttributes(in: inspected) { attrs, _, stop in
      let superscripts: [NSAttributedString.Key] = [.superscript,
        NSAttributedString.Key(kAXSuperscriptTextAttribute.takeUnretainedValue() as String)]
      let advancedStyle = superscripts.contains { key in
        guard let value = attrs[key] else { return false }
        return (value as? NSNumber)?.doubleValue != 0
      }
      if attrs[.attachment] != nil || attrs[.link] != nil ||
         advancedStyle ||
         (attrs[.paragraphStyle] as? NSParagraphStyle).map({ !$0.textBlocks.isEmpty || !$0.textLists.isEmpty }) == true {
        permitted = false; stop.pointee = true
      }
    }
    return permitted
  }
}

@MainActor
enum NativePastePayloadBuilder {
  static func prepare(_ plan: SentenceEditPlan,
                      attributedTarget: (NSRange) throws -> NSAttributedString) throws -> NativePastePayload {
    var inspectedSource: NSAttributedString?
    do {
      let source = try attributedTarget(plan.scope.target.range)
      guard source.string == plan.scope.target.text else { throw NativePasteError.stale(.sourceChanged) }
      inspectedSource = source
      let rich = try BasicRichText.replacement(source: source, text: plan.replacement)
        .attributedSubstring(from: plan.replacementRange)
      return try NativePastePayload(rtf: rich.data(from: NSRange(location: 0, length: rich.length),
        documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]))
    } catch NativePasteError.unsupportedFormat {
      guard ["com.apple.TextEdit", "com.microsoft.Word", "com.apple.Notes"].contains(plan.original.applicationIdentifier),
        let inspectedSource,
        NativePlainTextFallback.permits(inspectedSource,
          affected: NSRange(location: plan.range.location - plan.scope.target.range.location,
                            length: plan.range.length))
      else { throw NativePasteError.unsupportedFormat }
      return NativePastePayload()
    } catch NativePasteError.formatUnavailable {
      if let inspectedSource,
         !NativePlainTextFallback.permits(inspectedSource,
           affected: NSRange(location: plan.range.location - plan.scope.target.range.location,
                             length: plan.range.length)) {
        throw NativePasteError.unsupportedFormat
      }
      return NativePastePayload()
    }
  }
}

public extension NativePasteDriving {
  func preparePaste(_ plan: SentenceEditPlan) throws -> NativePastePayload {
    let source = try attributedTarget(plan.scope.target.range)
    guard source.string == plan.scope.target.text else { throw NativePasteError.stale(.sourceChanged) }
    let rich = try BasicRichText.replacement(source: source, text: plan.replacement)
      .attributedSubstring(from: plan.replacementRange)
    return try NativePastePayload(rtf: rich.data(from: NSRange(location: 0, length: rich.length),
      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]))
  }
}

public struct NativePasteResult: Sendable {
  public let clipboard: ClipboardRestoration
  public let caretPositioned: Bool
  public let preservesFormatting: Bool
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

  public func accept(_ plan: SentenceEditPlan, operation: UUID? = nil,
                     applicationIdentifier: String? = nil,
                     applicationName: String? = nil) async throws -> NativePasteResult {
    let start = ContinuousClock.now
    var progress = AcceptanceProgress()
    record(DiagnosticEvent(.acceptanceStarted, length: plan.scope.target.text.utf16.count), operation: operation,
      applicationIdentifier: applicationIdentifier, applicationName: applicationName)
    do {
      let result = try await perform(plan, operation: operation, progress: &progress,
        applicationIdentifier: applicationIdentifier, applicationName: applicationName)
      record(DiagnosticEvent(.acceptanceCompleted,
        level: result.clipboard == .failed || !result.caretPositioned ? .warning : .info,
        outcome: result.clipboard == .failed || !result.caretPositioned ? .warning : .success,
        durationMS: diagnosticMilliseconds(since: start), dispatched: true), operation: operation,
        applicationIdentifier: applicationIdentifier, applicationName: applicationName)
      return result
    } catch {
      record(DiagnosticEvent(.acceptanceFailed, level: error is CancellationError ? .info : .error,
        outcome: progress.dispatched ? .unconfirmed : (error is CancellationError ? .cancelled : .refused),
        reason: pasteDiagnosticReason(error), stage: progress.stage,
        durationMS: diagnosticMilliseconds(since: start), dispatched: progress.dispatched), operation: operation,
        applicationIdentifier: applicationIdentifier, applicationName: applicationName)
      throw error
    }
  }

  private struct AcceptanceProgress { var stage: DiagnosticStage = .preflight; var dispatched = false }

  private func record(_ event: DiagnosticEvent, operation: UUID?,
                      applicationIdentifier: String?, applicationName: String?) {
    diagnostics.record(event.withApplication(identifier: applicationIdentifier, name: applicationName),
      operation: operation)
  }

  private func perform(_ plan: SentenceEditPlan, operation: UUID?, progress: inout AcceptanceProgress,
                       applicationIdentifier: String?, applicationName: String?) async throws -> NativePasteResult {
    guard !isBusy else { throw NativePasteError.busy }
    isBusy = true
    defer { isBusy = false }
    try check(plan, current: driver.capture())
    record(DiagnosticEvent(.preflightPassed, stage: .preflight), operation: operation,
      applicationIdentifier: applicationIdentifier, applicationName: applicationName)
    progress.stage = .format
    let payload = try driver.preparePaste(plan)
    record(DiagnosticEvent(.formatPrepared,
      level: payload.preservesFormatting ? .info : .warning,
      outcome: payload.preservesFormatting ? .success : .warning,
      reason: payload.preservesFormatting ? nil : .plainTextFallback,
      stage: .format), operation: operation,
      applicationIdentifier: applicationIdentifier, applicationName: applicationName)
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
    try clipboard.begin(rtf: payload.rtf, text: plan.insertedText)
    record(DiagnosticEvent(.clipboardBorrowed, stage: .clipboard), operation: operation,
      applicationIdentifier: applicationIdentifier, applicationName: applicationName)
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
      record(DiagnosticEvent(.pasteDispatched, stage: .dispatch, dispatched: true), operation: operation,
        applicationIdentifier: applicationIdentifier, applicationName: applicationName)
      progress.stage = .verification

      // After dispatch, cancellation cannot roll back an external edit. Finish bounded
      // verification/clipboard cleanup and report uncertainty rather than pasting again.
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: .seconds(1.2))
      repeat {
        if let current = try? driver.capture(), sameDocument(current, plan.original),
          current.text == plan.expectedText
        {
          record(DiagnosticEvent(.pasteVerified, outcome: .success, stage: .verification), operation: operation,
            applicationIdentifier: applicationIdentifier, applicationName: applicationName)
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
          record(DiagnosticEvent(.caretChecked, outcome: positioned ? .success : .warning), operation: operation,
            applicationIdentifier: applicationIdentifier, applicationName: applicationName)
          progress.stage = .cleanup
          return NativePasteResult(clipboard: restoreClipboard(operation: operation,
            applicationIdentifier: applicationIdentifier, applicationName: applicationName),
            caretPositioned: positioned, preservesFormatting: payload.preservesFormatting)
        }
        try? await Task.sleep(for: .milliseconds(20))
      } while clock.now < deadline
      throw NativePasteError.resultUnconfirmed
    } catch {
      if !dispatched { restoreSelectionIfUnchanged(plan) }
      if restoreClipboard(operation: operation, applicationIdentifier: applicationIdentifier,
        applicationName: applicationName) == .failed {
        throw NativePasteError.clipboardRestorationFailed(dispatched: dispatched)
      }
      throw error
    }
  }

  private func restoreClipboard(operation: UUID?, applicationIdentifier: String?,
                                applicationName: String?) -> ClipboardRestoration {
    let result = clipboard.restore()
    let outcome: DiagnosticOutcome = switch result {
    case .restored: .restored; case .changedExternally: .superseded; case .failed: .failed
    }
    record(DiagnosticEvent(.clipboardRestored, level: result == .failed ? .warning : .info,
      outcome: outcome, stage: .cleanup), operation: operation,
      applicationIdentifier: applicationIdentifier, applicationName: applicationName)
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
public final class MacOSNativePasteDriver: NativePasteDriving {
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
    guard reader.capabilities?.editable == true,
      let focused = reader.capturedElement,
      AXUIElementGetPid(focused, &pid) == .success,
      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    else {
      throw NativePasteError.stale(.focusChanged)
    }
    element = focused
    return snapshot
  }
  public func preparePaste(_ plan: SentenceEditPlan) throws -> NativePastePayload {
    try NativePastePayloadBuilder.prepare(plan, attributedTarget: attributedTarget)
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
    let current = try reader.captureFocusedText()
    guard let focused = reader.capturedElement, CFEqual(focused, element),
      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { throw NativePasteError.selectionFailed }
    if current.selectedRange == range { return }
    var range = CFRange(location: range.location, length: range.length)
    guard let value = AXValueCreate(.cfRange, &range) else { throw NativePasteError.selectionFailed }
    for name in [kAXSelectedTextRangeAttribute, kAXSelectedTextRangesAttribute] {
      var settable = DarwinBoolean(false)
      guard AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success,
            settable.boolValue else { continue }
      let argument: CFTypeRef = name == kAXSelectedTextRangeAttribute ? value : [value] as CFArray
      // Some WebKit/Electron controls report the singular attribute as settable
      // but reject that write. Keep trying the plural representation instead of
      // turning a recoverable capability mismatch into a failed acceptance.
      guard AXUIElementSetAttributeValue(element, name as CFString, argument) == .success else {
        continue
      }
      if selectionMatches(element, range: range) { return }
      // A successful AX write may be reflected after the control's next run-loop
      // turn. Poll briefly; this remains bounded and happens only after acceptance.
      for _ in 0..<3 {
        usleep(10_000)
        if selectionMatches(element, range: range) { return }
      }
    }
    // Addressed WebKit/Word marker selection. The transaction immediately
    // recaptures and verifies the resulting numerical range before posting paste.
    var settable = DarwinBoolean(false)
    if AXUIElementIsAttributeSettable(element, "AXSelectedTextMarkerRange" as CFString, &settable) == .success,
       settable.boolValue,
       let start = AXEditorAccess.parameter(element, "AXTextMarkerForIndex", NSNumber(value: range.location)),
       let end = AXEditorAccess.parameter(element, "AXTextMarkerForIndex", NSNumber(value: range.location + range.length)),
       CFGetTypeID(start) == AXTextMarkerGetTypeID(), CFGetTypeID(end) == AXTextMarkerGetTypeID() {
      let markers = AXTextMarkerRangeCreate(nil, start as! AXTextMarker, end as! AXTextMarker)
      if AXUIElementSetAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, markers) == .success {
        if selectionMatches(element, range: range) { return }
        for _ in 0..<3 {
          usleep(10_000)
          if selectionMatches(element, range: range) { return }
        }
      }
    }
    throw NativePasteError.selectionFailed
  }

  private func selectionMatches(_ element: AXUIElement, range: CFRange) -> Bool {
    guard let actual = try? AXSelectionRange.read(element) else { return false }
    return actual.location == range.location && actual.length == range.length
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

/// Source-compatible names for the T2 baseline and its existing tests.
public typealias MacOSTextEditPasteDriver = MacOSNativePasteDriver
public typealias NativeTextPaste = NativeTextEditPaste
