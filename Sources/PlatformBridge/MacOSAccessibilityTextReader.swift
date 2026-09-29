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
}

/// Reads only text and selection exposed by macOS Accessibility. It never
/// presses Copy or changes the clipboard to manufacture a capture.
@MainActor
public final class MacOSAccessibilityTextReader: FocusedTextReading {
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

        var pid: pid_t = 0
        guard AXUIElementGetPid(focused, &pid) == .success,
              pid > 0,
              let appIdentifier = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
              !appIdentifier.isEmpty else {
            throw AccessibilityCaptureError.applicationUnavailable
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
}
