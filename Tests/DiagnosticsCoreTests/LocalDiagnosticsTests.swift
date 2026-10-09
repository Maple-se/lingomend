@testable import DiagnosticsCore
import Foundation
import XCTest

private final class FailingWriter: DiagnosticWriting {
    func open() throws {}
    func append(_ record: DiagnosticRecord) throws { throw SyntheticFailure.write }
    func clear() throws {}
    func close() {}
    private enum SyntheticFailure: Error { case write }
}
private final class BlockingWriter: DiagnosticWriting, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    func open() throws {}
    func append(_ record: DiagnosticRecord) throws { entered.signal(); _ = release.wait(timeout: .now() + 2) }
    func clear() throws {}
    func close() {}
}

final class LocalDiagnosticsTests: XCTestCase, @unchecked Sendable {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func contents(_ root: URL) throws -> String {
        try DiagnosticFileWriter.names.compactMap { name -> String? in
            let url = root.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try String(contentsOf: url, encoding: .utf8)
        }.joined()
    }
    func testExplicitChannelDefaultsAndIndependentKeys() {
        XCTAssertTrue(BuildChannel.development.defaultEnabled)
        XCTAssertFalse(BuildChannel.release.defaultEnabled)
        XCTAssertFalse(BuildChannel(metadata: nil).defaultEnabled)
        XCTAssertFalse(BuildChannel(metadata: "DEBUG").defaultEnabled)
        XCTAssertNotEqual(BuildChannel.development.preferenceKey, BuildChannel.release.preferenceKey)
    }
    func testOffCreatesNothing() async throws {
        let root = try temporary().appendingPathComponent("not-created")
        let logger = LocalDiagnostics(channel: .release, directory: root)
        await logger.setEnabled(false)
        logger.record(DiagnosticEvent(.appStarted))
        await logger.flush(); await logger.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertEqual(logger.status, .off)
    }
    func testCorrelationPrivacyAndPermissions() async throws {
        let root = try temporary(), operation = UUID()
        let secret = "synthetic-secret-do-not-log"
        let logger = LocalDiagnostics(channel: .development, version: secret, build: secret, directory: root)
        await logger.setEnabled(true)
        logger.record(DiagnosticEvent(.helpStarted, length: 7), operation: operation)
        logger.record(DiagnosticEvent(.modelCompleted, outcome: .suggest), operation: operation)
        await logger.flush()
        let text = try contents(root)
        XCTAssertFalse(text.contains(secret)); XCTAssertFalse(text.contains("replacement"))
        let records = try text.split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records[1]["operation"] as? String, operation.uuidString)
        XCTAssertEqual(records[2]["operation"] as? String, operation.uuidString)
        XCTAssertEqual(records.compactMap { $0["sequence"] as? Int }, [1, 2, 3])
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("runtime.log").path)[.posixPermissions] as? Int, 0o600)
        await logger.setEnabled(false)
    }
    func testOffDiscardsPendingAndAcknowledgesNoFurtherWrites() async throws {
        let root = try temporary()
        let logger = LocalDiagnostics(channel: .development, directory: root, batchDelay: 60)
        await logger.setEnabled(true); await logger.flush()
        let before = try contents(root)
        logger.record(DiagnosticEvent(.candidateShown))
        await logger.setEnabled(false)
        logger.record(DiagnosticEvent(.appStarted)); await logger.flush()
        XCTAssertEqual(try contents(root), before)
        XCTAssertEqual(logger.pendingCount, 0)
    }
    func testBoundedBufferDropsDebugBeforeImportantEvents() async throws {
        let root = try temporary()
        let logger = LocalDiagnostics(channel: .development, directory: root, batchDelay: 60)
        await logger.setEnabled(true); await logger.flush()
        for _ in 0..<600 { logger.record(DiagnosticEvent(.permissionChecked, level: .debug)) }
        logger.record(DiagnosticEvent(.acceptanceFailed, level: .error, dispatched: false))
        XCTAssertEqual(logger.pendingCount, 256)
        await logger.flush()
        let text = try contents(root)
        XCTAssertTrue(text.contains("eventsDropped")); XCTAssertTrue(text.contains("acceptanceFailed"))
        await logger.setEnabled(false)
    }
    func testClearDropsOldBufferPreservesForeignFilesAndSwitch() async throws {
        let root = try temporary(), foreign = root.appendingPathComponent("keep.txt")
        try Data("untouched".utf8).write(to: foreign)
        let logger = LocalDiagnostics(channel: .development, directory: root, batchDelay: 60)
        await logger.setEnabled(true)
        logger.record(DiagnosticEvent(.candidateShown))
        await logger.clear(); await logger.flush()
        XCTAssertEqual(logger.status, .active)
        XCTAssertFalse(try contents(root).contains("candidateShown"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
        await logger.setEnabled(false); await logger.clear()
        XCTAssertEqual(try contents(root), "")
    }
    func testIOFailureAndSecondWriterDoNotThrowToCaller() async throws {
        let root = try temporary()
        let first = LocalDiagnostics(channel: .development, directory: root)
        let second = LocalDiagnostics(channel: .development, directory: root)
        await first.setEnabled(true); await second.setEnabled(true)
        XCTAssertEqual(second.status, .unavailable)
        second.record(DiagnosticEvent(.appStarted)); await second.flush()
        XCTAssertEqual(second.pendingCount, 0)
        await first.setEnabled(false)
        let file = root.appendingPathComponent("not-a-directory")
        try Data().write(to: file)
        let bad = LocalDiagnostics(channel: .development, directory: file)
        await bad.setEnabled(true); XCTAssertEqual(bad.status, .unavailable)
    }
    func testRetentionAndRotationBounds() throws {
        let root = try temporary(), writer = DiagnosticFileWriter(directory: root)
        let old = root.appendingPathComponent("runtime.4.log")
        try Data("old".utf8).write(to: old)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-8 * 86400)], ofItemAtPath: old.path)
        try writer.open()
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        let session = UUID()
        try writer.append(DiagnosticRecord(timestamp: "2026-10-09T00:00:00Z", sequence: 0,
            session: session, operation: nil, event: DiagnosticEvent(.sessionStarted),
            channel: .development, version: "0.4.1", build: 6))
        for sequence in 1...22_000 {
            try writer.append(DiagnosticRecord(timestamp: "2026-10-09T00:00:00Z", sequence: UInt64(sequence),
                session: session, operation: UUID(), event: DiagnosticEvent(.modelCompleted, outcome: .suggest,
                length: 600, durationMS: 1000), channel: nil, version: nil, build: nil))
        }
        writer.close()
        let logs = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "log" }
        XCTAssertEqual(logs.count, 5)
        for log in logs {
            let data = try Data(contentsOf: log)
            XCTAssertLessThanOrEqual(data.count, DiagnosticFileWriter.fileLimit)
            let first = try JSONSerialization.jsonObject(with: Data(data.split(separator: 0x0a).first!)) as! [String: Any]
            XCTAssertEqual(first["channel"] as? String, "development")
            XCTAssertEqual(first["version"] as? String, "0.4.1")
            for line in data.split(separator: 0x0a) { XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line))) }
        }
    }
    func testRefusesSymlinkWithoutChangingTarget() async throws {
        let root = try temporary(), target = root.appendingPathComponent("private.txt")
        try Data("keep".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("runtime.log"), withDestinationURL: target)
        let logger = LocalDiagnostics(channel: .development, directory: root)
        await logger.setEnabled(true); XCTAssertEqual(logger.status, .unavailable)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep")
    }
    func testNumericFieldValidation() throws {
        let data = try JSONEncoder().encode(DiagnosticEvent(.modelFailed, length: -1, durationMS: -3, httpStatus: 999))
        let record = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(record["length"] as? Int, 0)
        XCTAssertNil(record["httpStatus"])
    }
    func testWriteFailureDisablesOnlyLoggerAndKeepsBufferEmpty() async {
        let logger = LocalDiagnostics(channel: .development, batchDelay: 60, writer: FailingWriter())
        await logger.setEnabled(true); await logger.flush()
        XCTAssertEqual(logger.status, .unavailable)
        logger.record(DiagnosticEvent(.modelCompleted)); await logger.flush()
        XCTAssertEqual(logger.pendingCount, 0)
        await logger.clear() // requested on stays on; retry fails at the next write, not silently off.
        XCTAssertEqual(logger.status, .active)
        await logger.flush(); XCTAssertEqual(logger.status, .unavailable)
    }
    func testShutdownDeadlineDoesNotWaitForStalledWriterAndCompletesOnce() async throws {
        let writer = BlockingWriter()
        let logger = LocalDiagnostics(channel: .development, batchDelay: 0, writer: writer)
        await logger.setEnabled(true)
        XCTAssertEqual(writer.entered.wait(timeout: .now() + 1), .success)
        let finished = expectation(description: "bounded shutdown")
        finished.assertForOverFulfill = true
        let start = ContinuousClock.now
        logger.finish(timeout: 0.03) { finished.fulfill() }
        await fulfillment(of: [finished], timeout: 0.5)
        XCTAssertLessThan(diagnosticMilliseconds(since: start), 500)
        writer.release.signal()
        await logger.flush()
    }
    func testPartialFinalLineIsRepairedAndOversizedExistingLogsPruned() async throws {
        let root = try temporary()
        try Data("{\"complete\":true}\n{\"partial\":".utf8).write(to: root.appendingPathComponent("runtime.log"))
        try Data(repeating: 0x20, count: DiagnosticFileWriter.fileLimit + 1).write(to: root.appendingPathComponent("runtime.2.log"))
        let logger = LocalDiagnostics(channel: .development, directory: root)
        await logger.setEnabled(true); await logger.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("runtime.2.log").path))
        let text = try contents(root)
        XCTAssertFalse(text.contains("partial"))
        for line in text.split(separator: "\n") { XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line.utf8))) }
        await logger.setEnabled(false)
    }
    func testConcurrentIngressRemainsBoundedAndValid() async throws {
        let root = try temporary()
        let logger = LocalDiagnostics(channel: .development, directory: root, batchDelay: 60)
        await logger.setEnabled(true); await logger.flush()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    for _ in 0..<400 { logger.record(DiagnosticEvent(.helpStarted), operation: UUID()) }
                }
            }
        }
        XCTAssertLessThanOrEqual(logger.pendingCount, LocalDiagnostics.bufferLimit)
        await logger.flush(); await logger.setEnabled(false)
        let records = try contents(root).split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
        let sequences = records.compactMap { $0["sequence"] as? UInt64 }
        XCTAssertEqual(sequences, sequences.sorted())
        XCTAssertEqual(Set(sequences).count, sequences.count)
    }
    func testLowerPriorityDoesNotEvictErrors() async throws {
        let root = try temporary()
        let logger = LocalDiagnostics(channel: .development, directory: root, batchDelay: 60)
        await logger.setEnabled(true); await logger.flush()
        for _ in 0..<256 { logger.record(DiagnosticEvent(.modelFailed, level: .error)) }
        logger.record(DiagnosticEvent(.candidateShown, level: .info))
        await logger.flush(); await logger.setEnabled(false)
        let text = try contents(root)
        XCTAssertFalse(text.contains("candidateShown"))
        XCTAssertEqual(text.components(separatedBy: "modelFailed").count - 1, 256)
        XCTAssertTrue(text.contains("eventsDropped"))
    }
}
