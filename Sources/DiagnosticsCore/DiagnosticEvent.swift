import Foundation

public enum BuildChannel: String, Codable, Sendable {
    case development, release, unknown
    public init(metadata: String?) { self = metadata.flatMap(Self.init(rawValue:)) ?? .unknown }
    public var defaultEnabled: Bool { self == .development }
    public var directoryName: String {
        switch self { case .development: "Development"; case .release: "Release"; case .unknown: "Unknown" }
    }
    public var preferenceKey: String { "LingoMend.diagnostics.\(rawValue).v1" }
}

public enum DiagnosticName: String, Codable, Sendable {
    case sessionStarted, appStarted, appStopping, permissionChecked, hotKeyRegistered
    case helpStarted, scopeResolved, helpFailed, candidateShown, candidateDismissed
    case readingStarted, readingCaptured, readingShown, readingFailed
    case modelStarted, providerInvoked, modelCompleted, modelFailed, cacheHit, throttleWait, cooldownRejected
    case acceptanceStarted, preflightPassed, formatPrepared, clipboardBorrowed, pasteDispatched
    case pasteVerified, caretChecked, clipboardRestored, acceptanceCompleted, acceptanceFailed
    case connectionTestStarted, connectionTestCompleted, connectionTestFailed, eventsDropped
}
public enum DiagnosticOutcome: String, Codable, Sendable {
    case success, failed, cancelled, refused, unconfirmed, warning
    case restored, superseded, unchanged, suggest, clarify, unsupported
}
public enum DiagnosticReason: String, Codable, Sendable {
    case userCancelled, superseded, sourceOrFocusChanged, settingsChanged
    case permissionRequired, captureUnavailable, applicationNotAllowed, empty, multipleSentences
    case tooLong, invalidRange, unsupportedInput, anchorUnavailable
    case focusedElementUnavailable, focusedWindowUnavailable, editableControlUnavailable
    case applicationUnavailable, textUnavailable, selectionUnavailable
    case focusChangedDuringCapture, protectedField, unsupportedApplication, writeUnsupported
    case configuration, credentials, unauthorized, rateLimited, http, network, timedOut
    case responseTooLarge, invalidResponse, incompleteResponse, refused, unknown
    case busy, stale, formatUnavailable, unsupportedFormat, modifiersHeld, clipboardUnavailable
    case plainTextFallback
    case clipboardChanged, selectionFailed, eventUnavailable, resultUnconfirmed, clipboardRestorationFailed
}
public enum DiagnosticStage: String, Codable, Sendable {
    case capture, scope, model, candidate, preflight, format, clipboard, selection, dispatch, verification, cleanup
}
public enum DiagnosticScope: String, Codable, Sendable { case selection, currentSentence, excerpt, selectionOnly }
public enum DiagnosticMode: String, Codable, Sendable { case local, network }
public enum DiagnosticShortcut: String, Codable, Sendable { case help, read, accept, cancelPeriod, cancelEscape }
public enum DiagnosticLevel: String, Codable, Sendable {
    case debug, info, warning, error
    var priority: Int { switch self { case .debug: 0; case .info: 1; case .warning: 2; case .error: 3 } }
}

/// Closed schema: no message, free-form metadata, Error, URL, text or object logging API.
/// The two application fields are bounded system-provided identity only; they never contain
/// editor contents, drafts, clipboard data, or model responses.
public struct DiagnosticEvent: Codable, Sendable {
    public let name: DiagnosticName
    public let level: DiagnosticLevel
    public let outcome: DiagnosticOutcome?
    public let reason: DiagnosticReason?
    public let stage: DiagnosticStage?
    public let scope: DiagnosticScope?
    public let mode: DiagnosticMode?
    public let shortcut: DiagnosticShortcut?
    public let length: Int?
    public let durationMS: Int?
    public let httpStatus: Int?
    public let dispatched: Bool?
    public let count: Int?
    public let applicationIdentifier: String?
    public let applicationName: String?

    public init(_ name: DiagnosticName, level: DiagnosticLevel = .info,
                outcome: DiagnosticOutcome? = nil, reason: DiagnosticReason? = nil,
                stage: DiagnosticStage? = nil, scope: DiagnosticScope? = nil,
                mode: DiagnosticMode? = nil, shortcut: DiagnosticShortcut? = nil,
                length: Int? = nil, durationMS: Int? = nil,
                httpStatus: Int? = nil, dispatched: Bool? = nil, count: Int? = nil,
                applicationIdentifier: String? = nil, applicationName: String? = nil) {
        self.name = name; self.level = level; self.outcome = outcome; self.reason = reason
        self.stage = stage; self.scope = scope; self.mode = mode
        self.shortcut = shortcut
        self.length = length.map { max(0, min($0, 1_000_000)) }
        self.durationMS = durationMS.map { max(0, min($0, 86_400_000)) }
        self.httpStatus = httpStatus.flatMap { (100...599).contains($0) ? $0 : nil }
        self.dispatched = dispatched; self.count = count.map { max(0, min($0, 1_000_000)) }
        self.applicationIdentifier = Self.boundedSystemValue(applicationIdentifier)
        self.applicationName = Self.boundedSystemValue(applicationName)
    }

    public func withApplication(identifier: String?, name: String?) -> DiagnosticEvent {
        DiagnosticEvent(self.name, level: level, outcome: outcome, reason: reason, stage: stage,
            scope: scope, mode: mode, shortcut: shortcut, length: length, durationMS: durationMS,
            httpStatus: httpStatus, dispatched: dispatched, count: count,
            applicationIdentifier: identifier, applicationName: name)
    }

    private static func boundedSystemValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 160,
              !trimmed.contains("\0"), !trimmed.contains("\n"), !trimmed.contains("\r") else {
            return nil
        }
        return trimmed
    }
}
public protocol DiagnosticRecording: Sendable {
    func record(_ event: DiagnosticEvent, operation: UUID?)
}
public extension DiagnosticRecording {
    func record(_ event: DiagnosticEvent) { record(event, operation: nil) }
}
public struct NoOpDiagnostics: DiagnosticRecording {
    public init() {}
    public func record(_ event: DiagnosticEvent, operation: UUID?) {}
}
public func diagnosticMilliseconds(since start: ContinuousClock.Instant) -> Int {
    let components = start.duration(to: ContinuousClock.now).components
    return Int(clamping: components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
}
