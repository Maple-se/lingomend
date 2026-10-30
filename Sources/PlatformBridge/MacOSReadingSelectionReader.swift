import AppKit
import ApplicationServices
import DiagnosticsCore

public struct ReadingCapture: Equatable, Sendable {
    public let id: UUID
    public let applicationIdentifier: String
    public let scope: ReadingScope
    /// Quartz coordinates. A missing anchor does not invalidate read-only interpretation.
    public let anchor: CGRect?
}

/// An AX range is an address, so a selected substring can be recovered from
/// the same element's complete value without searching for repeated words.
enum AXSelectionValueFallback {
    static func text(_ value: String?, range: NSRange?) -> String? {
        guard let value, let range, range.length > 0,
              value.utf16.count <= 65_536,
              range.location != NSNotFound, range.location >= 0,
              range.location <= value.utf16.count,
              range.length <= value.utf16.count - range.location,
              Range(range, in: value) != nil else { return nil }
        let units = Array(value.utf16)
        func splitsSurrogate(_ offset: Int) -> Bool {
            guard offset > 0, offset < units.count else { return false }
            return (0xD800...0xDBFF).contains(units[offset - 1])
                && (0xDC00...0xDFFF).contains(units[offset])
        }
        guard !splitsSurrogate(range.location), !splitsSurrogate(NSMaxRange(range)) else { return nil }
        return (value as NSString).substring(with: range)
    }
}

/// Explicit read-only capture. No synthetic Copy, clipboard access, OCR, or AX writes.
/// Standard ranges serve native editors/PDF views; opaque markers serve WebKit views.
@MainActor
public final class MacOSReadingSelectionReader {
    private struct Source {
        let capture: ReadingCapture
        let element: AXUIElement
        let focus: AXUIElement?
        let window: AXUIElement
        let pid: pid_t
        let marker: CFTypeRef?
        let multipleRanges: CFTypeRef?
        let range: NSRange?
        let rawSelection: String
    }
    private var source: Source?
    private var probe: AXCaptureProbe?
    var capturedElement: AXUIElement? { source?.element }
    public init() {}
    public func clear() { source = nil }

    public func capture(diagnostics: any DiagnosticRecording, operation: UUID) throws -> ReadingCapture {
        let collector = AXCaptureProbe()
        let app = NSWorkspace.shared.frontmostApplication
        var succeeded = false
        probe = collector
        defer {
            probe = nil
            if !succeeded, collector.stop == .matched { collector.stop = .refused }
            diagnostics.record(DiagnosticEvent(.captureChecked,
                outcome: collector.stop == .matched ? .success : .refused, stage: .capture, shortcut: .read,
                applicationIdentifier: app?.bundleIdentifier, applicationName: app?.localizedName,
                capture: collector.summary()), operation: operation)
        }
        let result = try capture(); succeeded = true; return result
    }

    /// Codex can publish its selection tree after the shortcut's initial read.
    /// One settling attempt stays bound to the original front process/window.
    public func captureAfterSettling(diagnostics: any DiagnosticRecording, operation: UUID) async throws -> ReadingCapture {
        let app = NSWorkspace.shared.frontmostApplication
        let window = app.flatMap {
            element(attribute(AXUIElementCreateApplication($0.processIdentifier), kAXFocusedWindowAttribute))
        }
        return try await CaptureSettling.run(sameSource: {
            guard let app, let window,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
                  let current = self.element(self.attribute(AXUIElementCreateApplication(app.processIdentifier),
                      kAXFocusedWindowAttribute)) else { return false }
            return CFEqual(window, current)
        }, retrying: { error in
            app?.bundleIdentifier == "com.openai.codex" && window != nil
                && (error == .selectionUnavailable || error == .focusedElementUnavailable)
        }, onRetry: { error in
            diagnostics.record(DiagnosticEvent(.captureSettling, reason: error.diagnosticReason,
                stage: .capture, shortcut: .read, count: 1,
                applicationIdentifier: app?.bundleIdentifier, applicationName: app?.localizedName), operation: operation)
        }, attempt: { try self.capture(diagnostics: diagnostics, operation: operation) })
    }

    public func capture() throws -> ReadingCapture {
        clear()
        guard AXIsProcessTrusted() else { throw AccessibilityCaptureError.permissionRequired }
        guard let app = NSWorkspace.shared.frontmostApplication,
              let identifier = app.bundleIdentifier, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw AccessibilityCaptureError.applicationUnavailable
        }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXEditorAccess.enable(application, probe: probe)
        guard let window = element(attribute(application, kAXFocusedWindowAttribute)) else {
            throw AccessibilityCaptureError.focusedElementUnavailable
        }
        let focus = focusedElement(application)
        if let focus, attribute(focus, kAXSubroleAttribute) as? String == "AXSecureTextField" {
            throw AccessibilityCaptureError.protectedField
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(focus ?? window, &pid) == .success, pid == app.processIdentifier else {
            throw AccessibilityCaptureError.focusChangedDuringCapture
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        var visited: [AXUIElement] = []
        // Prefer the focused element and its ancestors (Safari's focused leaf often has
        // no selection while its WebArea owns the selection marker range).
        var candidate: AXUIElement? = focus ?? window
        for _ in 0..<12 {
            guard let current = candidate, ContinuousClock.now < deadline else { break }
            visited.append(current)
            probe?.nodes = visited.count
            if let result = try read(current, identifier: identifier, focus: focus, window: window, pid: pid) {
                source = result
                probe?.stop = .matched
                guard isCurrent(result.capture) else { clear(); throw AccessibilityCaptureError.focusChangedDuringCapture }
                return result.capture
            }
            if CFEqual(current, window) { break }
            candidate = element(attribute(current, kAXParentAttribute))
        }
        // PDF/native document views may leave AX focus on a container. Search only the
        // front window, with fixed node/depth/time bounds; never scan background windows.
        var queue: [(AXUIElement, Int)] = [(window, 0)], index = 0
        var depthLimited = false
        while index < queue.count, index < 320, ContinuousClock.now < deadline {
            let (current, depth) = queue[index]; index += 1
            probe?.depth = max(probe?.depth ?? 0, depth)
            if !visited.contains(where: { CFEqual($0, current) }) {
                visited.append(current)
                probe?.nodes = visited.count
                if let result = try read(current, identifier: identifier, focus: focus, window: window, pid: pid) {
                    source = result
                    probe?.stop = .matched
                    guard isCurrent(result.capture) else { clear(); throw AccessibilityCaptureError.focusChangedDuringCapture }
                    return result.capture
                }
            }
            if depth < 12, AXEditorAccess.belongs(current, to: pid),
               attribute(current, kAXSubroleAttribute) as? String != "AXSecureTextField" {
                let children = AXEditorAccess.children(current, limit: 320 - queue.count, probe: probe)
                queue.append(contentsOf: children.map { ($0, depth + 1) })
            } else if depth >= 12 { depthLimited = true }
        }
        probe?.stop = ContinuousClock.now >= deadline ? .timeLimit
            : (index >= 320 || queue.count >= 320 ? .nodeLimit : (depthLimited ? .depthLimit : .exhausted))
        throw AccessibilityCaptureError.selectionUnavailable
    }

    /// Recheck the same addressed source, rather than searching for any matching word.
    public func isCurrent(_ capture: ReadingCapture) -> Bool {
        changeReason(for: capture) == nil
    }

    public func changeReason(for capture: ReadingCapture, diagnostics: (any DiagnosticRecording)? = nil,
                             operation: UUID? = nil) -> DiagnosticReason? {
        let previousProbe = probe
        let collector = diagnostics == nil ? nil : AXCaptureProbe()
        if let collector { probe = collector }
        defer { probe = previousProbe }
        let reason: DiagnosticReason?
        let detail: DiagnosticReason?
        do {
            reason = try recheck(capture)
            detail = reason
        } catch {
            reason = .sourceReadFailed
            detail = (error as? AccessibilityCaptureError)?.diagnosticReason ?? .captureUnavailable
        }
        if let detail {
            diagnostics?.record(DiagnosticEvent(.sourceRechecked, outcome: .refused,
                reason: detail, stage: .revalidation, shortcut: .read,
                applicationIdentifier: capture.applicationIdentifier,
                capture: collector?.summary()), operation: operation)
        }
        return reason
    }

    private func recheck(_ capture: ReadingCapture) throws -> DiagnosticReason? {
        guard let source, source.capture.id == capture.id else { return .sourceUnavailable }
        guard AXIsProcessTrusted() else { throw AccessibilityCaptureError.permissionRequired }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == source.pid else { return .focusChanged }
        let app = AXUIElementCreateApplication(source.pid)
        let focus = focusedElement(app)
        if focus == nil, source.focus != nil { throw AccessibilityCaptureError.focusedElementUnavailable }
        guard sameValue(focus, source.focus) else { return .focusChanged }
        guard let window = element(attribute(app, kAXFocusedWindowAttribute)) else {
            throw AccessibilityCaptureError.focusedWindowUnavailable
        }
        guard CFEqual(window, source.window) else { return .focusChanged }
        guard let fresh = try read(source.element, identifier: capture.applicationIdentifier,
            focus: focus, window: window, pid: source.pid) else { throw AccessibilityCaptureError.selectionUnavailable }
        // Opaque marker objects can be regenerated without a changed numerical
        // range. Compare verified indices when available; opaque-only captures
        // still require stable marker identity to disambiguate repeated text.
        let sameMarker = source.range != nil || sameValue(source.marker, fresh.marker)
        guard fresh.rawSelection == source.rawSelection, fresh.range == source.range,
              sameMarker, sameValue(source.multipleRanges, fresh.multipleRanges)
              else { return .selectionChanged }
        return fresh.capture.scope == capture.scope ? nil : .sourceChanged
    }

    private func focusedElement(_ application: AXUIElement) -> AXUIElement? {
        if let focus = element(AXEditorAccess.attribute(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute,
            probe: probe, api: .systemFocus)) {
            probe?.focus = .system
            probe?.focusRole = .init(systemRole: attribute(focus, kAXRoleAttribute) as? String)
            return focus
        }
        if let focus = element(AXEditorAccess.attribute(application, kAXFocusedUIElementAttribute,
            probe: probe, api: .applicationFocus)) {
            probe?.focus = .application
            probe?.focusRole = .init(systemRole: attribute(focus, kAXRoleAttribute) as? String)
            return focus
        }
        probe?.focus = .unavailable
        return nil
    }

    private func read(_ node: AXUIElement, identifier: String, focus: AXUIElement?,
                      window: AXUIElement, pid: pid_t) throws -> Source? {
        guard attribute(node, kAXSubroleAttribute) as? String != "AXSecureTextField" else { return nil }
        var owner: pid_t = 0
        guard AXUIElementGetPid(node, &owner) == .success, owner == pid else { return nil }
        let role = attribute(node, kAXRoleAttribute) as? String ?? ""
        probe?.role = CaptureDiagnostic.Role(systemRole: role)
        let range: NSRange?
        let multipleRanges: CFTypeRef?
        do { range = try AXSelectionRange.read(node, probe: probe); multipleRanges = nil }
        catch AccessibilityCaptureError.disjointSelection {
            // A read-only selection may be segmented (e.g. document lines). Explain the
            // actual selected text without inventing a contiguous context or edit address.
            range = nil; multipleRanges = attribute(node, kAXSelectedTextRangesAttribute)
        }
        let marker = multipleRanges == nil ? attribute(node, "AXSelectedTextMarkerRange") : nil
        if identifier == "com.microsoft.Word", role == "AXTextArea" {
            probe?.selection = range
            probe?.textLength = (attribute(node, kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue
        }
        let markerText = marker.flatMap { parameter(node, "AXStringForTextMarkerRange", $0) as? String }
        func nonempty(_ text: String?) -> String? {
            text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        }
        let raw = nonempty(markerText) ?? nonempty(attribute(node, kAXSelectedTextAttribute) as? String)
            ?? range.flatMap { range -> String? in
                guard range.length > 0, let argument = rangeArgument(range) else { return nil }
                if let text = nonempty(parameter(node, kAXStringForRangeParameterizedAttribute, argument) as? String) { return text }
                return nonempty((parameter(node, kAXAttributedStringForRangeParameterizedAttribute, argument) as? NSAttributedString)?.string)
            }
            ?? range.flatMap { range -> String? in
                guard range.length > 0 else { return nil }
                if let count = (attribute(node, kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue,
                   count > 65_536 { return nil }
                return nonempty(AXSelectionValueFallback.text(attribute(node, kAXValueAttribute) as? String,
                                                              range: range))
            }
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        probe?.candidates += 1
        probe?.selection = range
        probe?.textLength = raw.utf16.count
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
                      pid: pid, marker: marker, multipleRanges: multipleRanges, range: range, rawSelection: raw)
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
    private func sameValue(_ lhs: CFTypeRef?, _ rhs: CFTypeRef?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case (.some(let lhs), .some(let rhs)): return CFEqual(lhs, rhs)
        default: return false
        }
    }
    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        let api: CaptureDiagnostic.API? = switch name {
        case kAXValueAttribute: .value
        case kAXNumberOfCharactersAttribute: .characterCount
        case kAXSelectedTextAttribute: .selectedText
        case kAXFocusedWindowAttribute: .focusedWindow
        case "AXSelectedTextMarkerRange": .selectedMarker
        default: nil
        }
        return AXEditorAccess.attribute(element, name, probe: probe, api: api)
    }
    private func parameter(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef) -> CFTypeRef? {
        let api: CaptureDiagnostic.API? = switch name {
        case kAXStringForRangeParameterizedAttribute: .stringForRange
        case kAXAttributedStringForRangeParameterizedAttribute: .attributedStringForRange
        case "AXStringForTextMarkerRange": .stringForMarkerRange
        case "AXIndexForTextMarker": .markerIndex
        default: nil
        }
        return AXEditorAccess.parameter(element, name, argument, probe: probe, api: api)
    }
    private func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private func rangeArgument(_ range: NSRange) -> AXValue? {
        var value = CFRange(location: range.location, length: range.length)
        return AXValueCreate(.cfRange, &value)
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
