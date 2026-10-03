import CoachCore
import CryptoKit
import Foundation

/// Persists only expression cards and usage evidence, never the full draft.
public actor LocalLearningJournal {
    private struct JournalData: Codable {
        var expressions: [Expression] = []
        var evidence: [UsageEvidence] = []
    }

    private let fileURL: URL
    private let matcher = ReuseMatcher()
    private let reducer = MasteryStateReducer()

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            self.fileURL = support
                .appendingPathComponent("LingoMend", isDirectory: true)
                .appendingPathComponent("learning.json")
        }
    }

    @discardableResult
    public func save(_ point: LearningPoint) throws -> Expression {
        var journal = try load()
        if let existing = journal.expressions.first(where: {
            normalized($0.sourcePhrase) == normalized(point.source)
                && normalized($0.canonicalTarget) == normalized(point.target)
        }) {
            return existing
        }
        let expression = Expression(learningPoint: point)
        journal.expressions.append(expression)
        try persist(journal)
        return expression
    }

    /// Called only for a user-triggered capture, using the text before help.
    @discardableResult
    public func observeIndependentUse(
        in originalDraft: String,
        at date: Date = Date()
    ) throws -> [Expression] {
        var journal = try load()
        var changed: [Expression] = []
        let contextHash = fingerprint(originalDraft)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        for index in journal.expressions.indices {
            let expression = journal.expressions[index]
            // A known accepted suggestion is assisted even if pasted later.
            // Repeated identical drafts also cannot create new context evidence.
            guard !journal.evidence.contains(where: {
                $0.expressionID == expression.id && $0.contextHash == contextHash
                    && ($0.type == .assisted || $0.type == .independent)
            }) else { continue }
            // A same-day match could simply be a pasted suggestion. Wait for
            // a later day before calling reuse independent.
            guard !calendar.isDate(expression.createdAt, inSameDayAs: date) else {
                continue
            }
            guard let match = matcher.match(expression: expression, in: originalDraft) else {
                continue
            }
            let alreadyRecordedToday = journal.evidence.contains { item in
                item.expressionID == expression.id &&
                item.type == .independent &&
                calendar.isDate(item.occurredAt, inSameDayAs: date)
            }
            guard !alreadyRecordedToday else { continue }

            journal.evidence.append(
                UsageEvidence(
                    expressionID: expression.id,
                    type: .independent,
                    matchedText: match.matchedText,
                    confidence: match.confidence,
                    occurredAt: date,
                    contextHash: contextHash
                )
            )
            let evidence = journal.evidence.filter { $0.expressionID == expression.id }
            journal.expressions[index].state = reducer.state(for: evidence)
            journal.expressions[index].confidence = max(expression.confidence, match.confidence)
            changed.append(journal.expressions[index])
        }

        if !changed.isEmpty { try persist(journal) }
        return changed
    }

    public func expressions() throws -> [Expression] {
        try load().expressions
    }

    public func recordAssistedUse(in suggestion: String, at date: Date = Date()) throws {
        var journal = try load()
        let hash = fingerprint(suggestion)
        for expression in journal.expressions {
            guard let match = matcher.match(expression: expression, in: suggestion),
                  !journal.evidence.contains(where: {
                      $0.expressionID == expression.id && $0.type == .assisted && $0.contextHash == hash
                  }) else { continue }
            journal.evidence.append(UsageEvidence(
                expressionID: expression.id, type: .assisted, matchedText: match.matchedText,
                confidence: match.confidence, occurredAt: date, contextHash: hash
            ))
        }
        try persist(journal)
    }

    public func remove(expressionID: UUID) throws {
        var journal = try load()
        journal.expressions.removeAll { $0.id == expressionID }
        journal.evidence.removeAll { $0.expressionID == expressionID }
        try persist(journal)
    }

    public func clear() throws { try persist(JournalData()) }

    public func independentlyUsedExpressionCount(since date: Date) throws -> Int {
        Set(try load().evidence.filter { $0.type == .independent && $0.occurredAt >= date }
            .map(\.expressionID)).count
    }

    private func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func fingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(normalized(text).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func load() throws -> JournalData {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return JournalData()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(JournalData.self, from: Data(contentsOf: fileURL))
    }

    private func persist(_ journal: JournalData) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(journal).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }
}
