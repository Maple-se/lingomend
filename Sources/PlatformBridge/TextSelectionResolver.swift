import ApplicationServices
import Foundation
import DiagnosticsCore

/// A native paste can affect every caret in a multi-cursor editor. One proposal only
/// authorizes one continuous selection/caret; plural metadata must also agree with it.
public struct TextSelectionResolver: Sendable {
    public init() {}

    public func resolve(singular: NSRange?, plural: [NSRange]?) throws -> NSRange? {
        let candidates = (plural?.isEmpty == false ? plural! : singular.map { [$0] }) ?? []
        guard !candidates.isEmpty else { return nil }
        guard candidates.count == 1 else { throw AccessibilityCaptureError.disjointSelection }
        for range in candidates + (singular.map { [$0] } ?? []) {
            guard range.location >= 0, range.location != NSNotFound, range.length >= 0,
                  range.length <= Int.max - range.location else { throw AccessibilityCaptureError.invalidSelection }
        }
        let first = candidates[0]
        // Even adjacent carets/ranges may paste independently. Do not merge them into
        // a fictitious union that the native editor has never selected.
        guard singular == nil || singular == first else { throw AccessibilityCaptureError.invalidSelection }
        return first
    }
}

/// Internal adapter shared by read-only capture and editable capture.
enum AXSelectionRange {
    @MainActor static func read(_ element: AXUIElement, probe: AXCaptureProbe? = nil) throws -> NSRange? {
        func attribute(_ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            let code = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            probe?.record(name == kAXSelectedTextRangeAttribute ? .selectedRange : .selectedRanges, code)
            return code == .success ? value : nil
        }
        if let range = try decodeValues(singular: attribute(kAXSelectedTextRangeAttribute),
                                       plural: attribute(kAXSelectedTextRangesAttribute)) { return range }
        // Word/WebKit may publish opaque markers rather than numerical ranges.
        // Use their index API; never decode marker bytes or match repeated words.
        guard let value = AXEditorAccess.attribute(element, "AXSelectedTextMarkerRange", probe: probe, api: .selectedMarker),
              CFGetTypeID(value) == AXTextMarkerRangeGetTypeID() else { return nil }
        let markers = value as! AXTextMarkerRange
        guard let start = AXEditorAccess.parameter(element, "AXIndexForTextMarker",
                AXTextMarkerRangeCopyStartMarker(markers), probe: probe, api: .markerIndex) as? NSNumber,
              let end = AXEditorAccess.parameter(element, "AXIndexForTextMarker",
                AXTextMarkerRangeCopyEndMarker(markers), probe: probe, api: .markerIndex) as? NSNumber,
              start.intValue >= 0, end.intValue >= start.intValue else { return nil }
        return NSRange(location: start.intValue, length: end.intValue - start.intValue)
    }

    static func decodeValues(singular singularValue: CFTypeRef?, plural pluralValue: CFTypeRef?) throws -> NSRange? {
        let singular = try singularValue.flatMap(decode)
        let plural: [NSRange]?
        if let value = pluralValue {
            guard let values = value as? [AnyObject] else { throw AccessibilityCaptureError.invalidSelection }
            guard values.count <= 1 else { throw AccessibilityCaptureError.disjointSelection }
            plural = try values.compactMap { try decode($0 as CFTypeRef) }
        } else { plural = nil }
        return try TextSelectionResolver().resolve(singular: singular, plural: plural)
    }

    private static func decode(_ value: CFTypeRef) throws -> NSRange? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { throw AccessibilityCaptureError.invalidSelection }
        let ax = value as! AXValue
        var range = CFRange()
        guard AXValueGetType(ax) == .cfRange, AXValueGetValue(ax, .cfRange, &range) else {
            throw AccessibilityCaptureError.invalidSelection
        }
        // kCFNotFound is used by some read-only elements to mean "not exposed".
        if range.location == kCFNotFound { return nil }
        guard range.location >= 0, range.length >= 0, range.length <= Int.max - range.location else {
            throw AccessibilityCaptureError.invalidSelection
        }
        return NSRange(location: range.location, length: range.length)
    }
}
