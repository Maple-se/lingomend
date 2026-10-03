import AppKit
import ApplicationServices
import CryptoKit
import Foundation

public enum AccessibilityCaptureError: Error, Equatable, Sendable {
    case permissionRequired
    case focusedElementUnavailable
    case applicationUnavailable
    case textUnavailable
    case textTooLarge
    case selectionUnavailable
    case invalidSelection
    case focusChangedDuringCapture
    case protectedField
    case applicationNotAllowed
}

public enum AccessibilityReplacementError: Error, Equatable, Sendable {
    case explicitSelectionRequired
    case unsupportedApplication
    case invalidReplacement
    case staleCapture(ReplacementRefusal)
    case targetUnavailable
    case writeUnsupported
    case writeFailed
    case verificationFailed
}

/// Reads only text and selection exposed by macOS Accessibility. It never
/// presses Copy or changes the clipboard to manufacture a capture.
@MainActor
public final class MacOSAccessibilityTextReader: FocusedTextReading, SafeTextReplacing {
    /// Checked against the focused element's owning process before reading text.
    /// nil preserves explicit-capture callers; the companion app always sets a list.
    public var allowedApplications: Set<String>?
    private var previousElement: AXUIElement?
    private var previousElementIdentifier: String?

    public init() {}

    public func readFocusedText() async throws -> TextSnapshot {
        guard AXIsProcessTrusted() else {
            throw AccessibilityCaptureError.permissionRequired
        }

        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.5)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
        let focusedValue,
        CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            throw AccessibilityCaptureError.focusedElementUnavailable
        }
        let focused = focusedValue as! AXUIElement
        AXUIElementSetMessagingTimeout(focused, 0.5)

        var subrole: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(focused, kAXSubroleAttribute as CFString, &subrole)
        guard subrole as? String != "AXSecureTextField" else {
            throw AccessibilityCaptureError.protectedField
        }

        var pid: pid_t = 0
        guard AXUIElementGetPid(focused, &pid) == .success,
              pid > 0,
              let appIdentifier = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
              !appIdentifier.isEmpty else {
            throw AccessibilityCaptureError.applicationUnavailable
        }
        if let allowedApplications, !allowedApplications.contains(appIdentifier) {
            throw AccessibilityCaptureError.applicationNotAllowed
        }

        var textValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focused,
            kAXValueAttribute as CFString,
            &textValue
        ) == .success,
        let text = textValue as? String else {
            throw AccessibilityCaptureError.textUnavailable
        }

        var selectionValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focused,
            kAXSelectedTextRangeAttribute as CFString,
            &selectionValue
        ) == .success,
        let selectionValue,
        CFGetTypeID(selectionValue) == AXValueGetTypeID() else {
            throw AccessibilityCaptureError.selectionUnavailable
        }
        let axSelection = selectionValue as! AXValue
        guard AXValueGetType(axSelection) == .cfRange else {
            throw AccessibilityCaptureError.selectionUnavailable
        }

        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axSelection, .cfRange, &range),
              range.location >= 0,
              range.length >= 0 else {
            throw AccessibilityCaptureError.invalidSelection
        }

        let length = (text as NSString).length
        guard length <= 65_536 else {
            throw AccessibilityCaptureError.textTooLarge
        }
        guard range.location <= length,
              range.length <= length - range.location else {
            throw AccessibilityCaptureError.invalidSelection
        }

        var stillFocusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &stillFocusedValue
        ) == .success,
        let stillFocusedValue,
        CFGetTypeID(stillFocusedValue) == AXUIElementGetTypeID(),
        CFEqual(focused, stillFocusedValue) else {
            throw AccessibilityCaptureError.focusChangedDuringCapture
        }

        let elementIdentifier: String
        if let previousElement,
           let previousElementIdentifier,
           CFEqual(previousElement, focused) {
            elementIdentifier = previousElementIdentifier
        } else {
            elementIdentifier = UUID().uuidString
        }
        previousElement = focused
        previousElementIdentifier = elementIdentifier

        // AX has no universal edit revision. This is a content fingerprint;
        // replacement must still compare the full source and focused element.
        let digest = SHA256.hash(data: Data(text.utf8))
        let revisionToken = digest.map { String(format: "%02x", $0) }.joined()

        return TextSnapshot(
            applicationIdentifier: appIdentifier,
            focusedElementIdentifier: elementIdentifier,
            text: text,
            selectedRange: NSRange(location: range.location, length: range.length),
            revisionToken: revisionToken
        )
    }

    /// Quartz screen coordinates; the UI converts to AppKit coordinates.
    public func caretBounds(for original: TextSnapshot) async throws -> CGRect? {
        guard try await readFocusedText() == original, let focused = previousElement else { return nil }
        var range = CFRange(location: original.selectedRange.location, length: 0)
        guard let argument = AXValueCreate(.cfRange, &range) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(focused, kAXBoundsForRangeParameterizedAttribute as CFString,
              argument, &result) == .success, let result, CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
        let value = result as! AXValue
        var bounds = CGRect.zero
        guard AXValueGetType(value) == .cgRect, AXValueGetValue(value, .cgRect, &bounds),
              bounds.origin.x.isFinite, bounds.origin.y.isFinite,
              bounds.width.isFinite, bounds.height.isFinite, bounds.height > 0 else { return nil }
        return bounds
    }

    /// Experimental range acceptance. Changes only a verified placeholder;
    /// never synthesizes keystrokes or copies a draft into the clipboard.
    public func replaceInline(range: NSRange, source: String, in original: TextSnapshot,
                              with replacement: String) async throws {
        guard ["com.apple.TextEdit", "com.apple.Safari"].contains(original.applicationIdentifier) else {
            throw AccessibilityReplacementError.unsupportedApplication
        }
        guard !replacement.isEmpty, replacement.utf16.count <= 240, replacement != source else {
            throw AccessibilityReplacementError.invalidReplacement
        }
        let current = try await readFocusedText()
        if let refusal = ReplacementPreflight().rangeRefusal(original: original, current: current, range: range, source: source) {
            throw AccessibilityReplacementError.staleCapture(refusal)
        }
        guard let focused = previousElement else { throw AccessibilityReplacementError.targetUnavailable }
        for attribute in [kAXSelectedTextAttribute, kAXSelectedTextRangeAttribute] {
            var settable = DarwinBoolean(false)
            guard AXUIElementIsAttributeSettable(focused, attribute as CFString, &settable) == .success,
                  settable.boolValue else { throw AccessibilityReplacementError.writeUnsupported }
        }
        // No suspension between final validation, selection, and the addressed write.
        let final = try await readFocusedText()
        if let refusal = ReplacementPreflight().rangeRefusal(original: original, current: final, range: range, source: source) {
            throw AccessibilityReplacementError.staleCapture(refusal)
        }
        var selection = CFRange(location: range.location, length: range.length)
        guard let axRange = AXValueCreate(.cfRange, &selection),
              AXUIElementSetAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, axRange) == .success else {
            throw AccessibilityReplacementError.writeFailed
        }
        // Recheck addressed focus, text and actual selected range synchronously.
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.5)
        var focus: CFTypeRef?, text: CFTypeRef?, selected: CFTypeRef?
        var actual = CFRange(location: -1, length: -1)
        let valid = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focus) == .success
            && focus != nil && CFEqual(focused, focus!)
            && AXUIElementCopyAttributeValue(focused, kAXValueAttribute as CFString, &text) == .success
            && text as? String == original.text
            && AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, &selected) == .success
            && selected != nil && CFGetTypeID(selected!) == AXValueGetTypeID()
        let matches = valid && AXValueGetValue(selected as! AXValue, .cfRange, &actual)
            && actual.location == range.location && actual.length == range.length
        guard matches else {
            restoreSelection(focused, original: original)
            throw AccessibilityReplacementError.targetUnavailable
        }
        guard AXUIElementSetAttributeValue(focused, kAXSelectedTextAttribute as CFString, replacement as CFString) == .success else {
            restoreSelection(focused, original: original)
            throw AccessibilityReplacementError.writeFailed
        }
        let expected = (original.text as NSString).replacingCharacters(in: range, with: replacement)
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXValueAttribute as CFString, &result) == .success,
              result as? String == expected else { throw AccessibilityReplacementError.verificationFailed }
    }

    private func restoreSelection(_ focused: AXUIElement, original: TextSnapshot) {
        var current: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXValueAttribute as CFString, &current) == .success,
              current as? String == original.text else { return }
        var range = CFRange(location: original.selectedRange.location, length: original.selectedRange.length)
        if let value = AXValueCreate(.cfRange, &range) {
            _ = AXUIElementSetAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, value)
        }
    }

    public func replace(
        scope: ResolvedTextScope,
        in original: TextSnapshot,
        with replacement: String
    ) async throws {
        guard scope.kind == .explicitSelection else {
            throw AccessibilityReplacementError.explicitSelectionRequired
        }
        guard !replacement.isEmpty,
              (replacement as NSString).length <= 65_536,
              replacement != scope.text else {
            throw AccessibilityReplacementError.invalidReplacement
        }
        // Experimental targets only. AX writes and native undo still require
        // application-level validation; this method alone cannot certify undo.
        guard ["com.apple.TextEdit", "com.apple.Safari"].contains(original.applicationIdentifier) else {
            throw AccessibilityReplacementError.unsupportedApplication
        }

        let current = try await readFocusedText()
        if let refusal = ReplacementPreflight().refusal(
            original: original,
            current: current,
            scope: scope
        ) {
            throw AccessibilityReplacementError.staleCapture(refusal)
        }
        guard let focused = previousElement else {
            throw AccessibilityReplacementError.targetUnavailable
        }

        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            focused,
            kAXSelectedTextAttribute as CFString,
            &settable
        ) == .success,
        settable.boolValue else {
            throw AccessibilityReplacementError.writeUnsupported
        }

        let finalSnapshot = try await readFocusedText()
        if let refusal = ReplacementPreflight().refusal(
            original: original,
            current: finalSnapshot,
            scope: scope
        ) {
            throw AccessibilityReplacementError.staleCapture(refusal)
        }

        // The final focus check and AX write have no suspension point between
        // them. We address the checked element directly, never the current
        // keyboard target or the clipboard.
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.5)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
        let focusedValue,
        CFGetTypeID(focusedValue) == AXUIElementGetTypeID(),
        CFEqual(focused, focusedValue) else {
            throw AccessibilityReplacementError.targetUnavailable
        }

        guard AXUIElementSetAttributeValue(
            focused,
            kAXSelectedTextAttribute as CFString,
            replacement as CFString
        ) == .success else {
            throw AccessibilityReplacementError.writeFailed
        }

        let expected = (original.text as NSString).replacingCharacters(
            in: scope.range,
            with: replacement
        )
        var resultingValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focused,
            kAXValueAttribute as CFString,
            &resultingValue
        ) == .success,
        let resultingText = resultingValue as? String,
        resultingText == expected else {
            throw AccessibilityReplacementError.verificationFailed
        }
    }
}
