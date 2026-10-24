import AppKit
import ApplicationServices
import CryptoKit
import Foundation

public enum AccessibilityCaptureError: Error, Equatable, Sendable {
    case permissionRequired
    case focusedElementUnavailable
    case focusedWindowUnavailable
    case editableControlUnavailable
    case applicationUnavailable
    case textUnavailable
    case textTooLarge
    case selectionUnavailable
    case invalidSelection
    case disjointSelection
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
    public private(set) var capabilities: EditorCapabilities?

    public init() {}

    public func readFocusedText() async throws -> TextSnapshot {
        try captureFocusedText()
    }

    // Synchronous form for a final validation and addressed paste with no suspension in between.
    func captureFocusedText() throws -> TextSnapshot {
        guard AXIsProcessTrusted() else {
            throw AccessibilityCaptureError.permissionRequired
        }

        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.5)
        var focusedValue: CFTypeRef?
        let hasSystemFocus = AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success
        if hasSystemFocus, let focusedValue,
           CFGetTypeID(focusedValue) == AXUIElementGetTypeID() {
            let focused = focusedValue as! AXUIElement
            AXUIElementSetMessagingTimeout(focused, 0.5)
            return try captureFromFocused(focused, system: system)
        }

        // A few Electron/WebKit clients do not publish AXFocusedUIElement through
        // AXUIElementCreateSystemWide. Stay within the frontmost application and use
        // its focused window or a bounded editable-control search instead of guessing
        // from the clipboard or scanning background windows.
        return try captureFromFrontmostWindow(system: system)
    }

    private func captureFromFocused(_ focused: AXUIElement, system: AXUIElement,
                                    validationWindow: AXUIElement? = nil,
                                    expectedPID: pid_t? = nil) throws -> TextSnapshot {
        var candidate: AXUIElement? = focused
        var lastCaptureError: AccessibilityCaptureError = .textUnavailable
        for _ in 0..<8 {
            guard let current = candidate else { break }
            do {
                return try captureCandidate(current, system: system,
                    originalFocus: validationWindow == nil ? focused : nil,
                    validationWindow: validationWindow, expectedPID: expectedPID)
            } catch let error as AccessibilityCaptureError {
                switch error {
                case .textUnavailable, .selectionUnavailable:
                    lastCaptureError = error
                default:
                    throw error
                }
            }
            candidate = parent(of: current)
        }
        throw lastCaptureError
    }

    private func captureFromFrontmostWindow(system: AXUIElement) throws -> TextSnapshot {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let appIdentifier = app.bundleIdentifier, !appIdentifier.isEmpty else {
            throw AccessibilityCaptureError.applicationUnavailable
        }
        if let allowedApplications, !allowedApplications.contains(appIdentifier) {
            throw AccessibilityCaptureError.applicationNotAllowed
        }
        let pid = app.processIdentifier
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.3)
        guard let window = axElement(application, kAXFocusedWindowAttribute) else {
            throw AccessibilityCaptureError.focusedWindowUnavailable
        }
        AXUIElementSetMessagingTimeout(window, 0.3)

        var lastError: AccessibilityCaptureError = .focusedElementUnavailable
        if let windowFocus = axElement(window, kAXFocusedUIElementAttribute)
            ?? axElement(application, kAXFocusedUIElementAttribute) {
            do {
                return try captureFromFocused(windowFocus, system: system,
                    validationWindow: window, expectedPID: pid)
            } catch let error as AccessibilityCaptureError {
                switch error {
                case .textUnavailable, .selectionUnavailable, .focusedElementUnavailable:
                    lastError = error
                default:
                    throw error
                }
            }
        }

        let deadline = ContinuousClock.now.advanced(by: .milliseconds(350))
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var index = 0
        var visited: [AXUIElement] = []
        var fallback: [(AXUIElement, Int)] = []

        while index < queue.count, index < 160, ContinuousClock.now < deadline {
            let (current, depth) = queue[index]
            index += 1
            guard !visited.contains(where: { CFEqual($0, current) }) else { continue }
            visited.append(current)

            if isEditableCandidate(current) {
                let score = candidateScore(current)
                if (axAttribute(current, "AXFocused") as? Bool) == true {
                    do {
                        return try captureCandidate(current, system: system, originalFocus: nil,
                            validationWindow: window, expectedPID: pid)
                    } catch let error as AccessibilityCaptureError {
                        lastError = error
                    }
                } else if fallback.count < 16 {
                    fallback.append((current, score))
                }
            }

            if depth < 8, let children = axAttribute(current, kAXChildrenAttribute) as? [AXUIElement] {
                queue.append(contentsOf: children.prefix(max(0, 160 - queue.count)).map { ($0, depth + 1) })
            }
        }

        for (candidate, _) in fallback.sorted(by: { $0.1 > $1.1 }) {
            do {
                return try captureCandidate(candidate, system: system, originalFocus: nil,
                    validationWindow: window, expectedPID: pid)
            } catch let error as AccessibilityCaptureError {
                lastError = error
            }
        }
        throw fallback.isEmpty ? .editableControlUnavailable : lastError
    }

    private func isEditableCandidate(_ element: AXUIElement) -> Bool {
        let role = axAttribute(element, kAXRoleAttribute) as? String ?? ""
        let editable = axAttribute(element, "AXEditable") as? Bool
        let textRole = ["AXTextField", "AXTextArea", "AXComboBox", "AXWebArea"].contains(role)
        guard textRole || editable == true else { return false }
        return (axAttribute(element, kAXEnabledAttribute) as? Bool) != false
    }

    private func candidateScore(_ element: AXUIElement) -> Int {
        switch axAttribute(element, kAXRoleAttribute) as? String {
        case "AXTextArea": return 60
        case "AXTextField": return 50
        case "AXComboBox": return 40
        case "AXWebArea": return 20
        default: return 30
        }
    }

    private func axAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func axElement(_ owner: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = axAttribute(owner, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func isCurrentWindow(_ window: AXUIElement, pid: pid_t) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
        let application = AXUIElementCreateApplication(pid)
        guard let current = axElement(application, kAXFocusedWindowAttribute) else { return false }
        return CFEqual(window, current)
    }

    private func captureCandidate(_ focused: AXUIElement, system: AXUIElement,
                                  originalFocus: AXUIElement?, validationWindow: AXUIElement? = nil,
                                  expectedPID: pid_t? = nil) throws -> TextSnapshot {
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
        guard pid != ProcessInfo.processInfo.processIdentifier else { throw AccessibilityCaptureError.applicationNotAllowed }

        guard let text = try readText(from: focused) else {
            throw AccessibilityCaptureError.textUnavailable
        }

        guard let range = try AXSelectionRange.read(focused) else {
            throw AccessibilityCaptureError.selectionUnavailable
        }

        let length = (text as NSString).length
        guard length <= 65_536 else {
            throw AccessibilityCaptureError.textTooLarge
        }
        guard range.location <= length,
              range.length <= length - range.location else {
            throw AccessibilityCaptureError.invalidSelection
        }

        if let originalFocus {
            var stillFocusedValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                system,
                kAXFocusedUIElementAttribute as CFString,
                &stillFocusedValue
            ) == .success,
            let stillFocusedValue,
            CFGetTypeID(stillFocusedValue) == AXUIElementGetTypeID(),
            CFEqual(originalFocus, stillFocusedValue) else {
                throw AccessibilityCaptureError.focusChangedDuringCapture
            }
        } else if let validationWindow, let expectedPID,
                  !isCurrentWindow(validationWindow, pid: expectedPID) {
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
        func attribute(_ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(focused, name as CFString, &value) == .success ? value : nil
        }
        func settable(_ name: String) -> Bool {
            var value = DarwinBoolean(false)
            return AXUIElementIsAttributeSettable(focused, name as CFString, &value) == .success && value.boolValue
        }
        capabilities = EditorCapabilities(role: attribute(kAXRoleAttribute) as? String ?? "",
            enabled: (attribute(kAXEnabledAttribute) as? Bool) != false,
            explicitlyEditable: attribute("AXEditable") as? Bool,
            valueSettable: settable(kAXValueAttribute), selectedTextSettable: settable(kAXSelectedTextAttribute),
            rangeSettable: settable(kAXSelectedTextRangeAttribute) || settable(kAXSelectedTextRangesAttribute))

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

    private func parent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    var capturedElement: AXUIElement? { previousElement }

    /// Some WebKit/Electron and custom rich-text controls do not expose AXValue, but do
    /// expose their character count plus AXStringForRange. Prefer the complete value and
    /// use that bounded range API before refusing the request. This does not use Copy or
    /// infer a range from selected text, so the sentence boundary remains authoritative.
    private func readText(from element: AXUIElement) throws -> String? {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
           let text = textValue(value) {
            return text
        }

        var countValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXNumberOfCharactersAttribute as CFString, &countValue
        ) == .success,
        let count = (countValue as? NSNumber)?.intValue,
        count >= 0, count <= 65_536 else {
            return nil
        }
        var range = CFRange(location: 0, length: count)
        guard let argument = AXValueCreate(.cfRange, &range) else { return nil }
        var rangedValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString,
            argument, &rangedValue
        ) == .success else { return nil }
        return textValue(rangedValue)
    }

    private func textValue(_ value: CFTypeRef?) -> String? {
        if let text = value as? String { return text }
        if let string = value as? NSString { return String(string) }
        if let attributed = value as? NSAttributedString { return attributed.string }
        return nil
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
