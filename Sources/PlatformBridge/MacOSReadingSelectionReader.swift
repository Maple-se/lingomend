import AppKit
import ApplicationServices

public struct ReadingCapture: Equatable, Sendable {
    public let id: UUID
    public let applicationIdentifier: String
    public let scope: ReadingScope
    /// Quartz coordinates. A missing anchor does not invalidate read-only interpretation.
    public let anchor: CGRect?
}

/// Explicit read-only capture. No synthetic Copy, clipboard access, OCR, or AX writes.
/// Standard ranges serve native editors/PDF views; opaque markers serve WebKit views.
@MainActor
public final class MacOSReadingSelectionReader {
    private struct Source {
        let capture: ReadingCapture
        let element: AXUIElement
        let focus: AXUIElement
        let window: AXUIElement
        let pid: pid_t
        let marker: CFTypeRef?
        let range: NSRange?
        let rawSelection: String
    }
    private var source: Source?
    var capturedElement: AXUIElement? { source?.element }
    public init() {}
    public func clear() { source = nil }

    public func capture() throws -> ReadingCapture {
        clear()
        guard AXIsProcessTrusted() else { throw AccessibilityCaptureError.permissionRequired }
        guard let app = NSWorkspace.shared.frontmostApplication,
              let identifier = app.bundleIdentifier, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw AccessibilityCaptureError.applicationUnavailable
        }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = element(attribute(application, kAXFocusedWindowAttribute)),
              let focus = element(attribute(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute)) else {
            throw AccessibilityCaptureError.focusedElementUnavailable
        }
        if attribute(focus, kAXSubroleAttribute) as? String == "AXSecureTextField" {
            throw AccessibilityCaptureError.protectedField
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(focus, &pid) == .success, pid == app.processIdentifier else {
            throw AccessibilityCaptureError.focusChangedDuringCapture
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        var visited: [AXUIElement] = []
        // Prefer the focused element and its ancestors (Safari's focused leaf often has
        // no selection while its WebArea owns the selection marker range).
        var candidate: AXUIElement? = focus
        for _ in 0..<12 {
            guard let current = candidate, ContinuousClock.now < deadline else { break }
            visited.append(current)
            if let result = try read(current, identifier: identifier, focus: focus, window: window, pid: pid) {
                source = result
                guard isCurrent(result.capture) else { clear(); throw AccessibilityCaptureError.focusChangedDuringCapture }
                return result.capture
            }
            if CFEqual(current, window) { break }
            candidate = element(attribute(current, kAXParentAttribute))
        }
        // PDF/native document views may leave AX focus on a container. Search only the
        // front window, with fixed node/depth/time bounds; never scan background windows.
        var queue: [(AXUIElement, Int)] = [(window, 0)], index = 0
        while index < queue.count, index < 80, ContinuousClock.now < deadline {
            let (current, depth) = queue[index]; index += 1
            if !visited.contains(where: { CFEqual($0, current) }) {
                visited.append(current)
                if let result = try read(current, identifier: identifier, focus: focus, window: window, pid: pid) {
                    source = result
                    guard isCurrent(result.capture) else { clear(); throw AccessibilityCaptureError.focusChangedDuringCapture }
                    return result.capture
                }
            }
            if depth < 8, attribute(current, kAXSubroleAttribute) as? String != "AXSecureTextField",
               let children = attribute(current, kAXChildrenAttribute) as? [AXUIElement] {
                queue.append(contentsOf: children.prefix(max(0, 80 - queue.count)).map { ($0, depth + 1) })
            }
        }
        throw AccessibilityCaptureError.selectionUnavailable
    }

    /// Recheck the same addressed source, rather than searching for any matching word.
    public func isCurrent(_ capture: ReadingCapture) -> Bool {
        guard let source, source.capture.id == capture.id,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == source.pid,
              let focus = element(attribute(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute)),
              CFEqual(focus, source.focus),
              let window = element(attribute(AXUIElementCreateApplication(source.pid), kAXFocusedWindowAttribute)),
              CFEqual(window, source.window),
              let fresh = try? read(source.element, identifier: capture.applicationIdentifier,
                focus: focus, window: window, pid: source.pid),
              fresh.rawSelection == source.rawSelection, fresh.range == source.range,
              fresh.capture.scope == capture.scope else { return false }
        if let marker = source.marker {
            guard let current = fresh.marker, CFEqual(marker, current) else { return false }
        }
        return true
    }

    private func read(_ node: AXUIElement, identifier: String, focus: AXUIElement,
                      window: AXUIElement, pid: pid_t) throws -> Source? {
        guard attribute(node, kAXSubroleAttribute) as? String != "AXSecureTextField" else { return nil }
        var owner: pid_t = 0
        guard AXUIElementGetPid(node, &owner) == .success, owner == pid else { return nil }
        let range = rangeValue(attribute(node, kAXSelectedTextRangeAttribute))
        let marker = attribute(node, "AXSelectedTextMarkerRange")
        let markerText = marker.flatMap { parameter(node, "AXStringForTextMarkerRange", $0) as? String }
        let raw = markerText ?? attribute(node, kAXSelectedTextAttribute) as? String
            ?? range.flatMap { rangeArgument($0).flatMap { parameter(node, kAXStringForRangeParameterizedAttribute, $0) as? String } }
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let role = attribute(node, kAXRoleAttribute) as? String ?? ""
        let isPDF = identifier == "com.apple.Preview" || role.localizedCaseInsensitiveContains("pdf")
        let resolver = ReadingScopeResolver()
        var scope = try resolver.selectionOnly(raw, isPDF: isPDF)
        var anchor: CGRect?
        if let range, range.length > 0, let argument = rangeArgument(range) {
            anchor = rectValue(parameter(node, kAXBoundsForRangeParameterizedAttribute, argument))
            // Avoid requesting whole large documents. Bounded range APIs can provide an
            // excerpt even where AXValue is absent (PDF/readonly native text).
            let count = (attribute(node, kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue
            if count == nil || count! <= 65_536,
               let text = attribute(node, kAXValueAttribute) as? String, text.utf16.count <= 65_536,
               matches(raw, range: range, in: text) {
                scope = try resolver.resolve(text: text, selection: range, isPDF: isPDF)
            } else if let count, count >= 0, range.location <= count, range.length <= count - range.location {
                let start = max(0, range.location - 400)
                let end = min(count, NSMaxRange(range) + 400)
                if let snippetRange = rangeArgument(NSRange(location: start, length: end - start)),
                   let text = parameter(node, kAXStringForRangeParameterizedAttribute, snippetRange) as? String {
                    let local = NSRange(location: range.location - start, length: range.length)
                    if matches(raw, range: local, in: text) {
                        scope = try resolver.resolve(text: text, selection: local, isPDF: isPDF,
                                                     contextIsPartial: start > 0 || end < count)
                    }
                }
            }
        }
        if anchor == nil, let marker {
            anchor = rectValue(parameter(node, "AXBoundsForTextMarkerRange", marker))
        }
        if scope.availability == .selectionOnly, let marker,
           let contextual = markerScope(node, marker: marker, selection: raw, isPDF: isPDF) {
            scope = contextual
        }
        let capture = ReadingCapture(id: UUID(), applicationIdentifier: identifier, scope: scope, anchor: anchor)
        return Source(capture: capture, element: node, focus: focus, window: window,
                      pid: pid, marker: marker, range: range, rawSelection: raw)
    }

    /// Text markers are opaque. Use the system's marker endpoints and WebKit's advertised
    /// index/sentence APIs; never decode marker bytes or guess the first occurrence of a word.
    private func markerScope(_ node: AXUIElement, marker: CFTypeRef, selection: String, isPDF: Bool) -> ReadingScope? {
        guard CFGetTypeID(marker) == AXTextMarkerRangeGetTypeID() else { return nil }
        let selected = marker as! AXTextMarkerRange
        let start = AXTextMarkerRangeCopyStartMarker(selected)
        let end = AXTextMarkerRangeCopyEndMarker(selected)
        guard let startIndex = parameter(node, "AXIndexForTextMarker", start) as? NSNumber,
              let endIndex = parameter(node, "AXIndexForTextMarker", end) as? NSNumber,
              startIndex.intValue >= 0, endIndex.intValue >= startIndex.intValue else { return nil }
        for name in ["AXSentenceTextMarkerRangeForTextMarker", "AXParagraphTextMarkerRangeForTextMarker"] {
            guard let contextMarker = parameter(node, name, start),
                  CFGetTypeID(contextMarker) == AXTextMarkerRangeGetTypeID() else { continue }
            let range = contextMarker as! AXTextMarkerRange
            let contextStart = AXTextMarkerRangeCopyStartMarker(range)
            let contextEnd = AXTextMarkerRangeCopyEndMarker(range)
            guard let lower = parameter(node, "AXIndexForTextMarker", contextStart) as? NSNumber,
                  let upper = parameter(node, "AXIndexForTextMarker", contextEnd) as? NSNumber,
                  lower.intValue >= 0, lower.intValue <= startIndex.intValue,
                  endIndex.intValue <= upper.intValue, upper.intValue >= lower.intValue,
                  upper.intValue - lower.intValue <= 2_000,
                  let text = parameter(node, "AXStringForTextMarkerRange", range) as? String,
                  text.utf16.count <= 2_000 else { continue }
            let local = NSRange(location: startIndex.intValue - lower.intValue,
                                length: endIndex.intValue - startIndex.intValue)
            guard matches(selection, range: local, in: text) else { continue }
            return try? ReadingScopeResolver().resolve(text: text, selection: local, isPDF: isPDF)
        }
        return nil
    }

    private func matches(_ selection: String, range: NSRange, in text: String) -> Bool {
        range.location <= text.utf16.count && range.length <= text.utf16.count - range.location
            && Range(range, in: text) != nil && (text as NSString).substring(with: range) == selection
    }
    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.08)
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    private func parameter(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyParameterizedAttributeValue(element, name as CFString, argument, &value) == .success ? value : nil
    }
    private func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private func rangeArgument(_ range: NSRange) -> AXValue? {
        var value = CFRange(location: range.location, length: range.length)
        return AXValueCreate(.cfRange, &value)
    }
    private func rangeValue(_ value: CFTypeRef?) -> NSRange? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let ax = value as! AXValue
        var range = CFRange()
        guard AXValueGetType(ax) == .cfRange, AXValueGetValue(ax, .cfRange, &range),
              range.location >= 0, range.length >= 0, range.length <= Int.max - range.location else { return nil }
        return NSRange(location: range.location, length: range.length)
    }
    private func rectValue(_ value: CFTypeRef?) -> CGRect? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let ax = value as! AXValue
        var rect = CGRect.zero
        guard AXValueGetType(ax) == .cgRect, AXValueGetValue(ax, .cgRect, &rect),
              rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite,
              rect.height > 0 else { return nil }
        return rect
    }
}
