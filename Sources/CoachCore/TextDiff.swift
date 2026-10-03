import Foundation

public enum DiffKind: Sendable { case unchanged, removed, inserted }
public struct DiffSegment: Equatable, Sendable {
    public let text: String
    public let kind: DiffKind
}

/// Bounded token diff; concatenating unchanged + removed reconstructs source,
/// while unchanged + inserted reconstructs the suggestion.
public struct TextDiff: Sendable {
    public init() {}

    public func segments(from source: String, to suggestion: String) -> [DiffSegment] {
        let before = tokens(source), after = tokens(suggestion)
        guard before.count <= 2_000, after.count <= 2_000 else {
            return coarseDiff(source, suggestion)
        }
        let changes = after.difference(from: before)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in changes {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var result: [DiffSegment] = [], i = 0, j = 0
        while i < before.count || j < after.count {
            if i < before.count, removed.contains(i) {
                append(before[i], kind: .removed, to: &result); i += 1
            } else if j < after.count, inserted.contains(j) {
                append(after[j], kind: .inserted, to: &result); j += 1
            } else if i < before.count, j < after.count {
                append(before[i], kind: .unchanged, to: &result); i += 1; j += 1
            } else if i < before.count {
                append(before[i], kind: .removed, to: &result); i += 1
            } else {
                append(after[j], kind: .inserted, to: &result); j += 1
            }
        }
        return result
    }

    public func changedFraction(from source: String, to suggestion: String) -> Double {
        let edited = segments(from: source, to: suggestion)
            .filter { $0.kind != .unchanged }.reduce(0) { $0 + $1.text.count }
        return min(1, Double(edited) / Double(max(source.count, suggestion.count, 1)))
    }

    private func tokens(_ text: String) -> [String] {
        var result: [String] = [], word = ""
        for character in text {
            if character.isLetter || character.isNumber {
                word.append(character)
            } else {
                if !word.isEmpty { result.append(word); word = "" }
                result.append(String(character))
            }
        }
        if !word.isEmpty { result.append(word) }
        return result
    }

    private func coarseDiff(_ source: String, _ suggestion: String) -> [DiffSegment] {
        let before = Array(source), after = Array(suggestion)
        var prefix = 0, suffix = 0
        while prefix < min(before.count, after.count), before[prefix] == after[prefix] { prefix += 1 }
        while suffix < min(before.count, after.count) - prefix,
              before[before.count - suffix - 1] == after[after.count - suffix - 1] { suffix += 1 }
        var result: [DiffSegment] = []
        append(String(before.prefix(prefix)), kind: .unchanged, to: &result)
        append(String(before[prefix..<(before.count - suffix)]), kind: .removed, to: &result)
        append(String(after[prefix..<(after.count - suffix)]), kind: .inserted, to: &result)
        append(String(before.suffix(suffix)), kind: .unchanged, to: &result)
        return result
    }

    private func append(_ text: String, kind: DiffKind, to result: inout [DiffSegment]) {
        guard !text.isEmpty else { return }
        if let last = result.last, last.kind == kind {
            result[result.count - 1] = DiffSegment(text: last.text + text, kind: kind)
        } else { result.append(DiffSegment(text: text, kind: kind)) }
    }
}
