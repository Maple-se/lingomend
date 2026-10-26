import Foundation

/// Captured from the actual control, independently of the owning application's name.
public struct EditorCapabilities: Equatable, Sendable {
    public let editable: Bool
    public let selectableRange: Bool
    public let wordCompatibility: Bool
    public init(applicationIdentifier: String? = nil, role: String, enabled: Bool, explicitlyEditable: Bool?, valueSettable: Bool,
                selectedTextSettable: Bool, rangeSettable: Bool) {
        // WebKit/Electron editors often expose AXWebArea (or a custom role) instead
        // of AXTextArea. Settable value/selection attributes are the stronger signal
        // of editability and let those controls participate without treating a
        // read-only web document as writable.
        // Word's document page reports AXEnabled=false even while its native
        // editor accepts typing and undo. Limit the exception to its text area
        // when both its value and numerical selection are writable; the paste
        // transaction still verifies the same focused element, text and range.
        wordCompatibility = applicationIdentifier == "com.microsoft.Word" && role == "AXTextArea"
            && valueSettable && rangeSettable
        editable = wordCompatibility || (enabled && explicitlyEditable != false
            && (explicitlyEditable == true || valueSettable || selectedTextSettable))
        selectableRange = rangeSettable
    }
    public func canAccept(selection: NSRange) -> Bool { editable && (selectableRange || selection.length > 0) }
}
