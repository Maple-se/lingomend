import Foundation

/// Captured from the actual control, independently of the owning application's name.
public struct EditorCapabilities: Equatable, Sendable {
    public let editable: Bool
    public let selectableRange: Bool
    public init(role: String, enabled: Bool, explicitlyEditable: Bool?, valueSettable: Bool,
                selectedTextSettable: Bool, rangeSettable: Bool) {
        // WebKit/Electron editors often expose AXWebArea (or a custom role) instead
        // of AXTextArea. Settable value/selection attributes are the stronger signal
        // of editability and let those controls participate without treating a
        // read-only web document as writable.
        editable = enabled && explicitlyEditable != false
            && (explicitlyEditable == true || valueSettable || selectedTextSettable)
        selectableRange = rangeSettable
    }
    public func canAccept(selection: NSRange) -> Bool { editable && (selectableRange || selection.length > 0) }
}
