import Foundation

public enum ReadingContextAvailability: String, Equatable, Sendable {
    case sentence, excerpt, selectionOnly
}

/// Text-only value: never grants permission to edit the source.
public struct ReadingScope: Equatable, Sendable {
    public let selection: String
    public let before: String
    public let after: String
    public let availability: ReadingContextAvailability
    public var context: String { before + selection + after }
}

public enum ReadingScopeError: Error, Equatable, Sendable { case emptySelection, tooLong, invalidRange }

public struct ReadingScopeResolver: Sendable {
    public init() {}

    /// A range must refer to this exact text. Never locate a repeated word by first-match search.
    /// For PDFs, physical line wraps are collapsed; visible hyphens are retained because they
    /// might be meaningful (e.g. light-load). Discretionary soft hyphens may be removed.
    public func resolve(text: String, selection: NSRange, isPDF: Bool = false,
                        contextIsPartial: Bool = false) throws -> ReadingScope {
        let source = text as NSString
        guard selection.location >= 0, selection.location != NSNotFound, selection.length > 0,
              selection.location <= source.length, selection.length <= source.length - selection.location,
              let indices = Range(selection, in: text),
              text.indices.contains(indices.lowerBound),
              indices.upperBound == text.endIndex || text.indices.contains(indices.upperBound) else {
            throw ReadingScopeError.invalidRange
        }
        let prefix = normalize(String(text[..<indices.lowerBound]), isPDF: isPDF)
        let target = normalize(String(text[indices]), isPDF: isPDF)
        let suffix = normalize(String(text[indices.upperBound...]), isPDF: isPDF)
        _ = try selectionOnly(target)
        let normalized = prefix + target + suffix
        let selected = NSRange(location: prefix.utf16.count, length: target.utf16.count)
        let snapshot = TextSnapshot(applicationIdentifier: "", focusedElementIdentifier: "",
            text: normalized, selectedRange: selected, revisionToken: "")
        if let scope = try? SentenceScopeResolver(maximumLength: 2_000).resolve(snapshot) {
            let context = scope.context.range
            return ReadingScope(selection: target,
                before: (normalized as NSString).substring(with: NSRange(location: context.location,
                    length: selected.location - context.location)),
                after: (normalized as NSString).substring(with: NSRange(location: NSMaxRange(selected),
                    length: NSMaxRange(context) - NSMaxRange(selected))),
                availability: contextIsPartial ? .excerpt : .sentence)
        }
        // A short multi-sentence selection remains useful, but is not labelled a complete
        // containing sentence. Only bounded adjacent text is used for this fallback.
        let before = boundedSuffix(prefix, limit: min(400, (2_000 - target.utf16.count) / 2))
        let after = boundedPrefix(suffix, limit: 2_000 - target.utf16.count - before.utf16.count)
        return ReadingScope(selection: target, before: before, after: after, availability: .excerpt)
    }

    public func selectionOnly(_ selection: String, isPDF: Bool = false) throws -> ReadingScope {
        let text = normalize(selection, isPDF: isPDF)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReadingScopeError.emptySelection
        }
        guard text.utf16.count <= 1_200 else { throw ReadingScopeError.tooLong }
        return ReadingScope(selection: text, before: "", after: "", availability: .selectionOnly)
    }

    private func normalize(_ text: String, isPDF: Bool) -> String {
        guard isPDF else { return text }
        return text.replacingOccurrences(of: "\u{00AD}\r\n", with: "")
            .replacingOccurrences(of: "\u{00AD}\n", with: "")
            .replacingOccurrences(of: "\u{00AD}", with: "")
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private func boundedPrefix(_ text: String, limit: Int) -> String {
        var count = 0
        return String(text.prefix { character in
            count += String(character).utf16.count; return count <= limit
        })
    }
    private func boundedSuffix(_ text: String, limit: Int) -> String {
        var count = 0
        return String(text.reversed().prefix { character in
            count += String(character).utf16.count; return count <= limit
        }.reversed())
    }
}
