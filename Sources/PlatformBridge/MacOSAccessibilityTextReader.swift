import AppKit
import ApplicationServices
import CryptoKit
import Foundation
import DiagnosticsCore

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
    private var probe: AXCaptureProbe?

    public init() {}

    public func readFocusedText() async throws -> TextSnapshot {
        try captureFocusedText()
    }

    public func readFocusedText(diagnostics: any DiagnosticRecording, operation: UUID) async throws -> TextSnapshot {
        let collector = AXCaptureProbe()
        probe = collector
        let app = NSWorkspace.shared.frontmostApplication
        var succeeded = false
        defer {
            if probe === collector { probe = nil }
            if !succeeded, collector.stop == .matched { collector.stop = .refused }
            diagnostics.record(DiagnosticEvent(.captureChecked,
                outcome: collector.stop == .matched ? .success : .refused, stage: .capture,
                applicationIdentifier: app?.bundleIdentifier, applicationName: app?.localizedName,
                capture: collector.summary()), operation: operation)
        }
        do { let result = try captureFocusedText(); succeeded = true; return result }
        catch let error as AccessibilityCaptureError {
            guard error == .editableControlUnavailable || error == .focusedElementUnavailable
                || error == .textUnavailable || error == .selectionUnavailable else { throw error }
            let pid = app?.processIdentifier
            // One bounded settling attempt for a lazily enabled AX tree, only
            // during an explicit shortcut, never during final preflight.
            try await Task.sleep(for: .milliseconds(100))
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                throw AccessibilityCaptureError.focusChangedDuringCapture
            }
            let result = try captureFocusedText(); succeeded = true; return result
        }
    }

    // Synchronous form for a final validation and addressed paste with no suspension in between.
    func captureFocusedText() throws -> TextSnapshot {
        guard AXIsProcessTrusted() else {
            throw AccessibilityCaptureError.permissionRequired
        }

        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.5)
        var focusedValue: CFTypeRef?
        let focusCode = AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )
        probe?.record(.systemFocus, focusCode)
        var initialError: AccessibilityCaptureError = .focusedElementUnavailable
        if focusCode == .success, let focusedValue,
           CFGetTypeID(focusedValue) == AXUIElementGetTypeID() {
            let focused = focusedValue as! AXUIElement
            AXUIElementSetMessagingTimeout(focused, 0.5)
            probe?.focus = .system
            probe?.focusRole = .init(systemRole: axAttribute(focused, kAXRoleAttribute) as? String)
            do { return try captureFromFocused(focused, system: system) }
            catch let error as AccessibilityCaptureError {
                guard error == .textUnavailable || error == .selectionUnavailable else { throw error }
                initialError = error
                // Word and virtualized editors may focus a container/empty proxy.
                // Continue to the same application's focused descendants.
            }
        }

        // A few Electron/WebKit clients do not publish AXFocusedUIElement through
        // AXUIElementCreateSystemWide. Stay within the frontmost application and use
        // its focused window or a bounded editable-control search instead of guessing
        // from the clipboard or scanning background windows.
        return try captureFromFrontmostWindow(system: system, initialError: initialError)
    }

    private func captureFromFocused(_ focused: AXUIElement, system: AXUIElement,
                                    validationWindow: AXUIElement? = nil,
                                    expectedPID: pid_t? = nil) throws -> TextSnapshot {
        var candidate: AXUIElement? = focused
        var lastCaptureError: AccessibilityCaptureError = .textUnavailable
        for _ in 0..<8 {
            guard let current = candidate else { break }
            let role = axAttribute(current, kAXRoleAttribute) as? String
            if role == "AXWindow" || role == "AXApplication" { break }
            do {
                let snapshot = try captureCandidate(current, system: system,
                    originalFocus: validationWindow == nil ? focused : nil,
                    validationWindow: validationWindow, expectedPID: expectedPID)
                if !snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return snapshot
                }
                probe?.stop = .refused
                lastCaptureError = .textUnavailable
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

    private func captureFromFrontmostWindow(system: AXUIElement,
        initialError: AccessibilityCaptureError = .focusedElementUnavailable) throws -> TextSnapshot {
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
        AXUIElementSetMessagingTimeout(application, 0.08)
        AXEditorAccess.enable(application, probe: probe)
        guard let window = axElement(application, kAXFocusedWindowAttribute) else {
            throw AccessibilityCaptureError.focusedWindowUnavailable
        }
        AXUIElementSetMessagingTimeout(window, 0.3)

        var lastError = initialError
        let applicationFocus = axElement(application, kAXFocusedUIElementAttribute)
        let windowFocus = AXEditorAccess.element(AXEditorAccess.attribute(window, kAXFocusedUIElementAttribute,
            probe: probe, api: .windowFocus))
        var focusRoots: [AXUIElement] = []
        for focused in [applicationFocus, windowFocus].compactMap({ $0 }) {
            if focusRoots.contains(where: { CFEqual($0, focused) }) { continue }
            focusRoots.append(focused)
            guard AXEditorAccess.belongs(focused, to: pid) else { throw AccessibilityCaptureError.focusChangedDuringCapture }
            probe?.focus = applicationFocus.map { CFEqual($0, focused) } == true ? .application : .window
            probe?.focusRole = .init(systemRole: axAttribute(focused, kAXRoleAttribute) as? String)
            do {
                return try captureFromFocused(focused, system: system,
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

        // Focus evidence is required. A role score is not permission to read or
        // paste into a different field in the same window. Focus containers may
        // own an editor descendant; otherwise only AXFocused nodes are eligible.
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(900))
        var queue: [(AXUIElement, Int)] = focusRoots.map { ($0, 0) }
        if !focusRoots.contains(where: { CFEqual($0, window) }) { queue.append((window, 0)) }
        var index = 0
        var visited: [AXUIElement] = []
        var depthLimited = false
        var descendants: [AXUIElement] = []
        let containerRoots = focusRoots.filter {
            let role = axAttribute($0, kAXRoleAttribute) as? String
            return role != "AXWindow" && role != "AXApplication"
        }
        probe?.stop = .exhausted

        while index < queue.count, index < 320, ContinuousClock.now < deadline {
            let (current, depth) = queue[index]
            index += 1
            guard !visited.contains(where: { CFEqual($0, current) }) else { continue }
            visited.append(current)
            probe?.nodes = visited.count
            probe?.depth = max(probe?.depth ?? 0, depth)
            guard AXEditorAccess.belongs(current, to: pid) else { continue }
            if axAttribute(current, kAXSubroleAttribute) as? String == "AXSecureTextField" { continue }

            if isEditableCandidate(current) {
                probe?.candidates += 1
                if (axAttribute(current, "AXFocused") as? Bool) == true {
                    probe?.focus = .focusedDescendant
                    do {
                        return try captureFromFocused(current, system: system,
                            validationWindow: window, expectedPID: pid)
                    } catch let error as AccessibilityCaptureError {
                        guard error == .textUnavailable || error == .selectionUnavailable else { throw error }
                        lastError = error
                    }
                } else if containerRoots.contains(where: { isDescendant(current, of: $0) }),
                          isSettable(current, kAXValueAttribute) || isSettable(current, kAXSelectedTextAttribute) {
                    descendants.append(current)
                }
            }

            if depth < 12 {
                let children = axChildren(of: current)
                queue.append(contentsOf: children.prefix(max(0, 320 - queue.count)).map { ($0, depth + 1) })
            } else { depthLimited = true }
        }
        let stop: CaptureDiagnostic.Stop = ContinuousClock.now >= deadline ? .timeLimit
            : (index >= 320 || queue.count >= 320 ? .nodeLimit : (depthLimited ? .depthLimit : .exhausted))
        probe?.stop = stop
        // Only use uniqueness after a complete search of the focused subtree.
        if stop == .exhausted,
           let index = EditorCandidateSelection.uniqueFocusedDescendant(descendants.map { _ in true }) {
            probe?.focus = .focusedDescendant
            return try captureFromFocused(descendants[index], system: system,
                validationWindow: window, expectedPID: pid)
        }
        // No focus is different from an editor whose text interface is missing.
        // In particular a newly mounted web view can briefly expose neither.
        if focusRoots.isEmpty, lastError == .focusedElementUnavailable {
            throw AccessibilityCaptureError.focusedElementUnavailable
        }
        throw lastError == .focusedElementUnavailable ? .editableControlUnavailable : lastError
    }

    private func isEditableCandidate(_ element: AXUIElement) -> Bool {
        let role = axAttribute(element, kAXRoleAttribute) as? String ?? ""
        let editable = axAttribute(element, "AXEditable") as? Bool
        guard editable != false else { return false }
        let textRole = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXWebArea"].contains(role)
        guard textRole || editable == true || axAttribute(element, "AXFocused") as? Bool == true else { return false }
        return (axAttribute(element, kAXEnabledAttribute) as? Bool) != false
    }

    private func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var value = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &value) == .success && value.boolValue
    }

    private func isDescendant(_ node: AXUIElement, of root: AXUIElement) -> Bool {
        var candidate: AXUIElement? = node
        for _ in 0..<12 {
            guard let current = candidate else { break }
            if CFEqual(current, root) { return true }
            candidate = parent(of: current)
        }
        return false
    }


    /// Electron/WebKit sometimes exposes the editable node through AXContents or
    /// AXVisibleChildren instead of AXChildren. Read all bounded structural paths,
    /// preserving the focused-window-only scope.
    private func axChildren(of element: AXUIElement) -> [AXUIElement] {
        AXEditorAccess.children(element, probe: probe)
    }

    private func axAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        // A malformed or lazy web accessibility node must not hold the global
        // shortcut for seconds. Direct capture uses its own longer timeout when
        // it has already identified the editor.
        let api: CaptureDiagnostic.API? = switch name {
        case kAXFocusedWindowAttribute: .focusedWindow
        case kAXFocusedUIElementAttribute: .applicationFocus
        default: nil
        }
        return AXEditorAccess.attribute(element, name, probe: probe, api: api)
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
        probe?.textLength = nil; probe?.selection = nil; probe?.editable = nil
        probe?.valueSettable = nil; probe?.rangeSettable = nil; probe?.wordCompatibility = nil

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
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              expectedPID == nil || expectedPID == pid else { throw AccessibilityCaptureError.focusChangedDuringCapture }
        if let validationWindow, let ownerWindow = axElement(focused, kAXWindowAttribute),
           !CFEqual(validationWindow, ownerWindow) { throw AccessibilityCaptureError.focusChangedDuringCapture }
        probe?.role = CaptureDiagnostic.Role(systemRole: axAttribute(focused, kAXRoleAttribute) as? String)

        guard let text = try readText(from: focused) else {
            throw AccessibilityCaptureError.textUnavailable
        }
        probe?.textLength = text.utf16.count

        guard let range = try AXSelectionRange.read(focused, probe: probe) else {
            throw AccessibilityCaptureError.selectionUnavailable
        }
        probe?.selection = range

        let length = (text as NSString).length
        guard length <= 65_536 else {
            throw AccessibilityCaptureError.textTooLarge
        }
        guard range.location <= length,
              range.length <= length - range.location else {
            throw AccessibilityCaptureError.invalidSelection
        }
        if range.length > 0, let selected = textValue(axAttribute(focused, kAXSelectedTextAttribute)),
           !selected.isEmpty, (text as NSString).substring(with: range) != selected {
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
        let valueSettable = settable(kAXValueAttribute)
        let rangeSettable = settable(kAXSelectedTextRangeAttribute) || settable(kAXSelectedTextRangesAttribute)
            || settable("AXSelectedTextMarkerRange")
        capabilities = EditorCapabilities(applicationIdentifier: appIdentifier,
            role: attribute(kAXRoleAttribute) as? String ?? "",
            enabled: (attribute(kAXEnabledAttribute) as? Bool) != false,
            explicitlyEditable: attribute("AXEditable") as? Bool,
            valueSettable: valueSettable, selectedTextSettable: settable(kAXSelectedTextAttribute),
            rangeSettable: rangeSettable)
        probe?.editable = capabilities?.editable
        probe?.valueSettable = valueSettable
        probe?.rangeSettable = rangeSettable
        probe?.wordCompatibility = capabilities?.wordCompatibility
        probe?.stop = .matched

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
        let direct = textValue(AXEditorAccess.attribute(element, kAXValueAttribute, probe: probe, api: .value))
        if let direct, !direct.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return direct }
        if direct != nil { probe?.emptyValues += 1 }
        let countValue = AXEditorAccess.attribute(element, kAXNumberOfCharactersAttribute, probe: probe, api: .characterCount)
        var count = (countValue as? NSNumber)?.intValue
        if count == nil || count == 0,
           let end = AXEditorAccess.attribute(element, "AXEndTextMarker"),
           let index = AXEditorAccess.parameter(element, "AXIndexForTextMarker", end, probe: probe, api: .markerIndex) as? NSNumber {
            count = index.intValue
        }
        return try AXTextContent.resolve(value: direct, count: count) { requested in
          var range = CFRange(location: requested.location, length: requested.length)
          guard let argument = AXValueCreate(.cfRange, &range) else { return nil }
          for (name, api) in [(kAXStringForRangeParameterizedAttribute, CaptureDiagnostic.API.stringForRange),
                            (kAXAttributedStringForRangeParameterizedAttribute, .attributedStringForRange)] {
            if let text = textValue(AXEditorAccess.parameter(element, name, argument, probe: probe, api: api)),
               text.utf16.count == requested.length, !text.isEmpty { return text }
          }
          if let start = AXEditorAccess.attribute(element, "AXStartTextMarker"),
           let end = AXEditorAccess.attribute(element, "AXEndTextMarker"),
           CFGetTypeID(start) == AXTextMarkerGetTypeID(), CFGetTypeID(end) == AXTextMarkerGetTypeID() {
            let markers = AXTextMarkerRangeCreate(nil, start as! AXTextMarker, end as! AXTextMarker)
            if let text = textValue(AXEditorAccess.parameter(element, "AXStringForTextMarkerRange", markers)),
               text.utf16.count == requested.length { return text }
          }
          return nil
        }
    }

    private func textValue(_ value: CFTypeRef?) -> String? {
        if let text = value as? String { return text }
        if let string = value as? NSString { return String(string) }
        if let attributed = value as? NSAttributedString { return attributed.string }
        return nil
    }

    private func elementBounds(_ element: AXUIElement) -> CGRect? {
        guard let position = axAttribute(element, kAXPositionAttribute),
              let size = axAttribute(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        let positionValue = position as! AXValue
        let sizeValue = size as! AXValue
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetType(positionValue) == .cgPoint,
              AXValueGetValue(positionValue, .cgPoint, &point),
              AXValueGetType(sizeValue) == .cgSize,
              AXValueGetValue(sizeValue, .cgSize, &dimensions),
              point.x.isFinite, point.y.isFinite,
              dimensions.width.isFinite, dimensions.height.isFinite,
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private func rectValue(_ value: CFTypeRef?) -> CGRect? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let ax = value as! AXValue
        var rect = CGRect.zero
        guard AXValueGetType(ax) == .cgRect,
              AXValueGetValue(ax, .cgRect, &rect),
              rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite, rect.height > 0 else { return nil }
        return rect
    }

    /// Quartz screen coordinates; the UI converts to AppKit coordinates.
    public func caretBounds(for original: TextSnapshot) async throws -> CGRect? {
        guard try await readFocusedText() == original, let focused = previousElement else { return nil }
        var range = CFRange(location: original.selectedRange.location, length: 0)
        guard let argument = AXValueCreate(.cfRange, &range) else { return nil }
        var result: CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(focused, kAXBoundsForRangeParameterizedAttribute as CFString,
              argument, &result) == .success, let result, let bounds = rectValue(result) {
            return bounds
        }
        // WebKit/Electron controls may expose text and selection while omitting
        // AXBoundsForRange. The control frame remains a safe nearby anchor.
        guard let bounds = elementBounds(focused) else { return nil }
        return CGRect(x: bounds.minX, y: max(bounds.minY, bounds.maxY - 10),
                      width: max(1, bounds.width), height: min(max(10, bounds.height), 24))
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
