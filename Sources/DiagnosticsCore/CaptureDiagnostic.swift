import Foundation

/// Only fixed categories and bounded metrics. Never accepts AX titles, identifiers,
/// descriptions, text, marker bytes, window names or arbitrary error strings.
public struct CaptureDiagnostic: Codable, Sendable {
    public enum Focus: String, Codable, Sendable { case system, application, window, focusedDescendant, unavailable }
    public enum Role: String, Codable, Sendable {
        case textArea, textField, webArea, group, window, application, other
        public init(systemRole: String?) {
            switch systemRole {
            case "AXTextArea": self = .textArea
            case "AXTextField", "AXSearchField", "AXComboBox": self = .textField
            case "AXWebArea": self = .webArea
            case "AXGroup", "AXScrollArea", "AXLayoutArea": self = .group
            case "AXWindow": self = .window
            case "AXApplication": self = .application
            default: self = .other
            }
        }
    }
    public enum Stop: String, Codable, Sendable { case matched, exhausted, nodeLimit, timeLimit, depthLimit, refused }
    public enum API: String, Codable, Sendable {
        case systemFocus, applicationFocus, windowFocus, focusedWindow, children, contents, visibleChildren, selectedChildren
        case enhancedAccessibility, manualAccessibility, value, characterCount
        case stringForRange, attributedStringForRange, selectedRange, selectedRanges, selectedText, selectedMarker, markerIndex, stringForMarkerRange
    }
    public struct Result: Codable, Sendable {
        public let api: API
        public let code: Int
        public init(api: API, code: Int) { self.api = api; self.code = max(-100_000, min(code, 100_000)) }
    }
    public let focus: Focus
    public let role: Role
    public let focusRole: Role
    public let emptyValues: Int
    public let stop: Stop
    public let nodes: Int
    public let depth: Int
    public let candidates: Int
    public let textLength: Int?
    public let selectionLocation: Int?
    public let selectionLength: Int?
    public let editable: Bool?
    public let valueSettable: Bool?
    public let rangeSettable: Bool?
    public let wordCompatibility: Bool?
    public let results: [Result]
    public init(focus: Focus, role: Role, stop: Stop, nodes: Int, depth: Int, candidates: Int,
                textLength: Int? = nil, selectionLocation: Int? = nil, selectionLength: Int? = nil,
                editable: Bool? = nil, valueSettable: Bool? = nil, rangeSettable: Bool? = nil,
                wordCompatibility: Bool? = nil, results: [Result] = [],
                focusRole: Role = .other, emptyValues: Int = 0) {
        self.focus = focus; self.role = role; self.stop = stop
        self.nodes = max(0, min(nodes, 512)); self.depth = max(0, min(depth, 32))
        self.candidates = max(0, min(candidates, 512))
        self.textLength = textLength.map { max(0, min($0, 65_536)) }
        self.selectionLocation = selectionLocation.map { max(0, min($0, 65_536)) }
        self.selectionLength = selectionLength.map { max(0, min($0, 65_536)) }
        self.editable = editable
        self.valueSettable = valueSettable
        self.rangeSettable = rangeSettable
        self.wordCompatibility = wordCompatibility
        self.focusRole = focusRole; self.emptyValues = max(0, min(emptyValues, 512))
        self.results = Array(results.prefix(24))
    }
}
