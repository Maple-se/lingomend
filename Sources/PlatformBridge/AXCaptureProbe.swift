import AppKit
import ApplicationServices
import DiagnosticsCore

/// One collector per capture or source recheck; never retains AX objects or text.
@MainActor
final class AXCaptureProbe {
    var focus: CaptureDiagnostic.Focus = .unavailable
    var role: CaptureDiagnostic.Role = .other
    var focusRole: CaptureDiagnostic.Role = .other
    var emptyValues = 0
    var stop: CaptureDiagnostic.Stop = .refused
    var nodes = 0, depth = 0, candidates = 0
    var textLength: Int?, selection: NSRange?, editable: Bool?
    var valueSettable: Bool?, rangeSettable: Bool?, wordCompatibility: Bool?
    private var results: [CaptureDiagnostic.Result] = []
    func record(_ api: CaptureDiagnostic.API, _ code: AXError) {
        let result = CaptureDiagnostic.Result(api: api, code: Int(code.rawValue))
        if let i = results.firstIndex(where: { $0.api == api }) { results[i] = result }
        else if results.count < 24 { results.append(result) }
    }
    func summary() -> CaptureDiagnostic {
        CaptureDiagnostic(focus: focus, role: role, stop: stop, nodes: nodes, depth: depth,
            candidates: candidates, textLength: textLength, selectionLocation: selection?.location,
            selectionLength: selection?.length, editable: editable,
            valueSettable: valueSettable, rangeSettable: rangeSettable,
            wordCompatibility: wordCompatibility, results: results,
            focusRole: focusRole, emptyValues: emptyValues)
    }
}

/// Shared structural access for writing/reading. These paths never copy selection
/// or enumerate background windows. Every element is still validated by its reader.
@MainActor
enum AXEditorAccess {
    static func attribute(_ node: AXUIElement, _ name: String, probe: AXCaptureProbe? = nil,
                          api: CaptureDiagnostic.API? = nil) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(node, 0.08)
        var value: CFTypeRef?
        let code = AXUIElementCopyAttributeValue(node, name as CFString, &value)
        if let api { probe?.record(api, code) }
        return code == .success ? value : nil
    }
    static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    static func children(_ node: AXUIElement, limit: Int = 320, probe: AXCaptureProbe? = nil) -> [AXUIElement] {
        guard limit > 0 else { return [] }
        var result: [AXUIElement] = []
        for name in [kAXChildrenAttribute, kAXContentsAttribute, kAXVisibleChildrenAttribute,
                     kAXSelectedChildrenAttribute] {
            let api: CaptureDiagnostic.API = switch name {
            case kAXContentsAttribute: .contents
            case kAXVisibleChildrenAttribute: .visibleChildren
            case kAXSelectedChildrenAttribute: .selectedChildren
            default: .children
            }
            guard let values = attribute(node, name, probe: probe, api: api) as? [AnyObject] else { continue }
            for value in values.prefix(limit) {
                guard let child = element(value), !result.contains(where: { CFEqual($0, child) }) else { continue }
                result.append(child)
                if result.count >= limit { return result }
            }
        }
        return result
    }
    static func enable(_ application: AXUIElement, probe: AXCaptureProbe?) {
        for (name, api) in [("AXEnhancedUserInterface", CaptureDiagnostic.API.enhancedAccessibility),
                            ("AXManualAccessibility", .manualAccessibility)] {
            let code = AXUIElementSetAttributeValue(application, name as CFString, kCFBooleanTrue)
            probe?.record(api, code)
        }
    }
    static func belongs(_ node: AXUIElement, to pid: pid_t) -> Bool {
        var owner: pid_t = 0
        return AXUIElementGetPid(node, &owner) == .success && owner == pid
    }
    static func parameter(_ node: AXUIElement, _ name: String, _ argument: CFTypeRef,
                          probe: AXCaptureProbe? = nil, api: CaptureDiagnostic.API? = nil) -> CFTypeRef? {
        var result: CFTypeRef?
        let code = AXUIElementCopyParameterizedAttributeValue(node, name as CFString, argument, &result)
        if let api { probe?.record(api, code) }
        return code == .success ? result : nil
    }
}
