import Foundation

/// Structural failure details only. Never stores type names, URLs or clipboard bytes.
public struct ClipboardDiagnostic: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable {
        case itemsUnavailable, itemLimit, emptyTypes, typeLimit, promisedData
        case dataUnavailable, byteLimit, payloadUnavailable, writeFailed
    }
    public enum Size: String, Codable, Sendable {
        case empty, upTo64KiB, upTo1MiB, upTo4MiB, over4MiB
        public init(bytes: Int) {
            switch bytes {
            case ...0: self = .empty
            case ...65_536: self = .upTo64KiB
            case ...1_048_576: self = .upTo1MiB
            case ...4_194_304: self = .upTo4MiB
            default: self = .over4MiB
            }
        }
    }
    public let reason: Reason
    public let items: Int
    public let types: Int
    public let size: Size
    public init(reason: Reason, items: Int, types: Int, bytes: Int) {
        self.reason = reason
        self.items = max(0, min(items, 33))
        self.types = max(0, min(types, 65))
        self.size = Size(bytes: bytes)
    }
}
