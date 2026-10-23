import Foundation

/// Captured from the actual control, independently of the owning application's name.
public struct EditorCapabilities: Equatable, Sendable {
    public let editable: Bool
    public let selectableRange: Bool
    public init(role: String, enabled: Bool, explicitlyEditable: Bool?, valueSettable: Bool,
                selectedTextSettable: Bool, rangeSettable: Bool) {
        let textControl = ["AXTextField", "AXTextArea", "AXComboBox"].contains(role) || explicitlyEditable == true
        editable = enabled && textControl && explicitlyEditable != false
            && (explicitlyEditable == true || valueSettable || selectedTextSettable)
        selectableRange = rangeSettable
    }
    public func canAccept(selection: NSRange) -> Bool { editable && (selectableRange || selection.length > 0) }
}
