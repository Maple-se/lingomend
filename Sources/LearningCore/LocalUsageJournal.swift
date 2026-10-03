import CoachCore
import Foundation

public struct UsageSummary: Codable, Equatable, Sendable {
    public var requests = 0
    public var inputCharacters = 0
    public var chineseCharacters = 0
    public var changeFractionTotal: Double = 0
    public var copied = 0
    public var replaced = 0
    public init() {}
    public var chineseFraction: Double { Double(chineseCharacters) / Double(max(inputCharacters, 1)) }
    public var averageChangeFraction: Double { changeFractionTotal / Double(max(requests, 1)) }
}

/// Opt-in aggregate statistics: no drafts, titles, application IDs or API keys.
public actor LocalUsageJournal {
    private let fileURL: URL
    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LingoMend/usage.json")
    }
    public func record(source: String, suggestion: String) throws {
        var value = try summary()
        value.requests += 1
        value.inputCharacters += source.count
        value.chineseCharacters += source.unicodeScalars.filter {
            (0x3400...0x4DBF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value)
                || (0x20000...0x2FA1F).contains($0.value)
        }.count
        value.changeFractionTotal += TextDiff().changedFraction(from: source, to: suggestion)
        try persist(value)
    }
    public func recordAcceptance(replaced: Bool) throws {
        var value = try summary()
        if replaced { value.replaced += 1 } else { value.copied += 1 }
        try persist(value)
    }
    public func summary() throws -> UsageSummary {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return UsageSummary() }
        return try JSONDecoder().decode(UsageSummary.self, from: Data(contentsOf: fileURL))
    }
    public func clear() throws { try persist(UsageSummary()) }
    private func persist(_ value: UsageSummary) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                               withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(value).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
