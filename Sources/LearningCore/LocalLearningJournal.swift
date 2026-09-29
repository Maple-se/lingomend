import CoachCore
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
            $0.sourcePhrase == point.source && $0.canonicalTarget == point.target
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
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        for index in journal.expressions.indices {
            let expression = journal.expressions[index]
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
                    occurredAt: date
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
