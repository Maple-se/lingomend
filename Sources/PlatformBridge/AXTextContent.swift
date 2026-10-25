import Foundation

enum AXTextContent {
    /// Empty AXValue is common on virtualized editor proxies. A bounded range
    /// interface can still expose the actual text. Coordinates remain native.
    static func resolve(value: String?, count: Int?, readRange: (NSRange) -> String?) throws -> String? {
        if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return value }
        guard let count, count >= 0 else { return value }
        guard count <= 65_536 else { throw AccessibilityCaptureError.textTooLarge }
        if let text = readRange(NSRange(location: 0, length: count)), text.utf16.count == count { return text }
        return value
    }
}
