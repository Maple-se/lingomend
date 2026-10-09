import Foundation

public enum DiagnosticsStatus: String, Sendable { case off, starting, active, unavailable }

struct DiagnosticRecord: Encodable {
    let timestamp: String
    let sequence: UInt64
    let session: UUID
    let operation: UUID?
    let event: DiagnosticEvent
    let channel: BuildChannel?
    let version: String?
    let build: Int?
}

/// A synchronous, bounded ingress; disk IO is confined to one utility queue.
public final class LocalDiagnostics: DiagnosticRecording, @unchecked Sendable {
    public let directory: URL
    private let channel: BuildChannel
    private let version: String?
    private let build: Int?
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.maplese.lingomend.diagnostics", qos: .utility)
    private let writer: any DiagnosticWriting
    private var enabled = false
    private var requested = false
    private var state: DiagnosticsStatus = .off
    private var buffer: [DiagnosticRecord] = []
    private var scheduled = false
    private var generation: UInt64 = 0
    private var sequence: UInt64 = 0
    private var dropped = 0
    private var session = UUID()
    private let batchDelay: TimeInterval
    public static let bufferLimit = 256

    public convenience init(channel: BuildChannel, version: String? = nil, build: String? = nil,
                directory: URL? = nil, batchDelay: TimeInterval = 0.2) {
        self.init(channel: channel, version: version, build: build, directory: directory, batchDelay: batchDelay, writer: nil)
    }
    // Internal sink injection is for deterministic failure/shutdown tests, not public configuration.
    init(channel: BuildChannel, version: String? = nil, build: String? = nil,
         directory: URL? = nil, batchDelay: TimeInterval = 0.2, writer: (any DiagnosticWriting)?) {
        self.channel = channel
        // Bundle metadata is untrusted too. Only short numeric versions are retained.
        self.version = version.flatMap { value in
            value.count <= 24 && !value.isEmpty && value.allSatisfy { "0123456789.".contains($0) } ? value : nil
        }
        self.build = build.flatMap(Int.init).flatMap { $0 >= 0 && $0 <= 1_000_000 ? $0 : nil }
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/LingoMend/\(channel.directoryName)", isDirectory: true)
        self.writer = writer ?? DiagnosticFileWriter(directory: self.directory)
        self.batchDelay = max(0, batchDelay)
    }

    public var status: DiagnosticsStatus { lock.withLock { state } }
    public var pendingCount: Int { lock.withLock { buffer.count } }

    public func record(_ event: DiagnosticEvent, operation: UUID?) {
        lock.withLock {
            guard enabled else { return }
            if buffer.count == Self.bufferLimit {
                dropped = min(dropped + 1, 1_000_000)
                let candidate = buffer.indices.filter { buffer[$0].event.name != .sessionStarted }
                    .min { buffer[$0].event.level.priority < buffer[$1].event.level.priority }
                guard let index = candidate, buffer[index].event.level.priority <= event.level.priority else { return }
                buffer.remove(at: index)
            }
            buffer.append(makeRecord(event, operation: operation))
            scheduleLocked()
        }
    }

    /// Off gates new records immediately; the completion barrier guarantees no later old writes.
    public func setEnabled(_ value: Bool) async {
        let token = lock.withLock { () -> UInt64 in
            generation &+= 1; requested = value; enabled = false; buffer.removeAll(); dropped = 0; scheduled = false
            state = value ? .starting : .off
            return generation
        }
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard lock.withLock({ generation == token }) else { continuation.resume(); return }
                writer.close()
                if value {
                    do {
                        try writer.open()
                        lock.withLock {
                            guard generation == token else { return }
                            session = UUID(); sequence = 0; enabled = true; state = .active
                            buffer.append(makeRecord(DiagnosticEvent(.sessionStarted), operation: nil, header: true))
                            scheduleLocked()
                        }
                    } catch { fail(token) }
                }
                continuation.resume()
            }
        }
    }

    /// Discard pending records before clearing. Preserve the current requested switch.
    public func clear() async {
        let (token, wasEnabled) = lock.withLock { () -> (UInt64, Bool) in
            let wasEnabled = requested
            generation &+= 1; enabled = false; buffer.removeAll(); dropped = 0; scheduled = false
            return (generation, wasEnabled)
        }
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard lock.withLock({ generation == token }) else { continuation.resume(); return }
                do {
                    try writer.clear()
                    if wasEnabled { try writer.open() }
                    else { writer.close() }
                    lock.withLock {
                        guard generation == token else { return }
                        enabled = wasEnabled; state = wasEnabled ? .active : .off
                        if wasEnabled {
                            session = UUID(); sequence = 0
                            buffer.append(makeRecord(DiagnosticEvent(.sessionStarted), operation: nil, header: true))
                            scheduleLocked()
                        }
                    }
                } catch { fail(token) }
                continuation.resume()
            }
        }
    }

    public func flush() async {
        let token = lock.withLock { generation }
        await withCheckedContinuation { continuation in
            queue.async { [self] in drain(token); continuation.resume() }
        }
    }

    /// Shutdown never waits indefinitely for disk. Late OS writes may be lost on process exit.
    public func finish(timeout: TimeInterval = 0.3, completion: @escaping @Sendable () -> Void) {
        let once = CompletionOnce(completion)
        let token = lock.withLock { generation }
        queue.async { [self] in
            drain(token)
            lock.withLock { enabled = false; buffer.removeAll(); state = .off }
            writer.close(); once.call()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0, timeout)) { once.call() }
    }

    private func makeRecord(_ event: DiagnosticEvent, operation: UUID?, header: Bool = false) -> DiagnosticRecord {
        sequence &+= 1
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return DiagnosticRecord(timestamp: formatter.string(from: Date()), sequence: sequence,
            session: session, operation: operation, event: event,
            channel: header ? channel : nil, version: header ? version : nil, build: header ? build : nil)
    }
    private func scheduleLocked() {
        guard !scheduled else { return }
        scheduled = true
        let token = generation
        queue.asyncAfter(deadline: .now() + batchDelay) { [self] in drain(token) }
    }
    private func drain(_ token: UInt64) {
        // Keep queued events in the bounded buffer, not a second detached batch array.
        lock.withLock { if generation == token { scheduled = false } }
        do {
            for _ in 0..<Self.bufferLimit {
                let record = lock.withLock { () -> DiagnosticRecord? in
                    guard generation == token, enabled, !buffer.isEmpty else { return nil }
                    return buffer.removeFirst()
                }
                guard let record else { break }
                guard lock.withLock({ generation == token && enabled }) else { break }
                try writer.append(record)
            }
            let overflow = lock.withLock { () -> DiagnosticRecord? in
                guard generation == token, enabled else { return nil }
                // Wait until all preceding sequence numbers have drained.
                if !buffer.isEmpty { scheduleLocked(); return nil }
                guard dropped > 0 else { return nil }
                let record = makeRecord(DiagnosticEvent(.eventsDropped, level: .warning, count: dropped), operation: nil)
                dropped = 0; return record
            }
            if let overflow, lock.withLock({ generation == token && enabled }) { try writer.append(overflow) }
        } catch { fail(token) }
    }
    private func fail(_ token: UInt64) {
        lock.withLock {
            guard generation == token else { return }
            enabled = false; state = .unavailable; buffer.removeAll(); dropped = 0; scheduled = false
        }
        writer.close()
    }
}

private final class CompletionOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable () -> Void)?
    init(_ completion: @escaping @Sendable () -> Void) { self.completion = completion }
    func call() {
        let callback = lock.withLock { let value = completion; completion = nil; return value }
        callback?()
    }
}
