import DiagnosticsCore
@testable import PlatformBridge
import XCTest

private final class RecheckSpy: DiagnosticRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(DiagnosticEvent, UUID?)] = []
    var events: [(DiagnosticEvent, UUID?)] { lock.withLock { storage } }
    func record(_ event: DiagnosticEvent, operation: UUID?) {
        lock.withLock { storage.append((event, operation)) }
    }
}

final class CaptureValidationTests: XCTestCase {
    @MainActor func testSettlingMakesOnlyOneAttemptAfterFailureAndKeepsIdentityGuard() async throws {
        var attempts = 0, retries = 0
        let value: Int = try await CaptureSettling.run(sameSource: { true }, retrying: { _ in true },
            onRetry: { _ in retries += 1 }, attempt: {
                attempts += 1
                if attempts == 1 { throw AccessibilityCaptureError.selectionUnavailable }
                return 42
            })
        XCTAssertEqual(value, 42); XCTAssertEqual(attempts, 2); XCTAssertEqual(retries, 1)
        attempts = 0
        do {
            let _: Int = try await CaptureSettling.run(sameSource: { false }, retrying: { _ in true },
                onRetry: { _ in }, attempt: {
                    attempts += 1; throw AccessibilityCaptureError.focusedElementUnavailable
                })
            XCTFail("Must not retarget after window/process changed")
        } catch { XCTAssertEqual(error as? AccessibilityCaptureError, .focusChangedDuringCapture) }
        XCTAssertEqual(attempts, 1)
    }

    @MainActor func testPermissionAndProtectedFieldsNeverRetryAndCancellationStopsSettling() async throws {
        for error in [AccessibilityCaptureError.permissionRequired, .protectedField] {
            var attempts = 0
            do {
                let _: Int = try await CaptureSettling.run(sameSource: { true },
                    retrying: { $0 == .selectionUnavailable }, onRetry: { _ in XCTFail() }, attempt: {
                        attempts += 1; throw error
                    })
                XCTFail()
            } catch let actual as AccessibilityCaptureError { XCTAssertEqual(actual, error) }
            XCTAssertEqual(attempts, 1)
        }
        var attempts = 0
        let task = Task { @MainActor in
            let _: Int = try await CaptureSettling.run(sameSource: { true }, retrying: { _ in true },
                onRetry: { _ in }, attempt: {
                    attempts += 1; throw AccessibilityCaptureError.selectionUnavailable
                })
        }
        try await Task.sleep(for: .milliseconds(10)); task.cancel()
        do { try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(attempts, 1)
    }

    @MainActor func testPersistentFailureDoesNotLoopAndSuccessDoesNotWaitOrRetry() async throws {
        var attempts = 0
        do {
            let _: Int = try await CaptureSettling.run(sameSource: { true }, retrying: { _ in true },
                onRetry: { _ in }, attempt: {
                    attempts += 1; throw AccessibilityCaptureError.selectionUnavailable
                })
            XCTFail()
        } catch { XCTAssertEqual(error as? AccessibilityCaptureError, .selectionUnavailable) }
        XCTAssertEqual(attempts, 2)
        let value = try await CaptureSettling.run(sameSource: { XCTFail(); return false },
            retrying: { _ in XCTFail(); return false }, onRetry: { _ in XCTFail() }, attempt: { 7 })
        XCTAssertEqual(value, 7)
    }

    @MainActor func testReadingMissingSourceLogsSpecificCauseWithoutSelectionContents() throws {
        let reader = MacOSReadingSelectionReader(), spy = RecheckSpy(), operation = UUID()
        let capture = ReadingCapture(id: UUID(), applicationIdentifier: "synthetic.editor",
            scope: try ReadingScopeResolver().selectionOnly("PRIVATE_SELECTION"), anchor: nil)
        XCTAssertEqual(reader.changeReason(for: capture, diagnostics: spy, operation: operation), .sourceUnavailable)
        let event = try XCTUnwrap(spy.events.first?.0)
        XCTAssertEqual(event.name, .sourceRechecked)
        XCTAssertEqual(event.stage, .revalidation); XCTAssertEqual(event.reason, .sourceUnavailable)
        XCTAssertEqual(event.shortcut, .read); XCTAssertEqual(spy.events.first?.1, operation)
        let encoded = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        XCTAssertFalse(encoded.contains("PRIVATE_SELECTION"))
        reader.clear()
        XCTAssertEqual(reader.changeReason(for: capture), .sourceUnavailable)
        XCTAssertEqual(spy.events.count, 1)
    }
    func testCaptureErrorReasonsRemainDistinct() {
        XCTAssertEqual(AccessibilityCaptureError.permissionRequired.diagnosticReason, .permissionRequired)
        XCTAssertEqual(AccessibilityCaptureError.focusedElementUnavailable.diagnosticReason, .focusedElementUnavailable)
        XCTAssertEqual(AccessibilityCaptureError.textUnavailable.diagnosticReason, .textUnavailable)
        XCTAssertEqual(AccessibilityCaptureError.selectionUnavailable.diagnosticReason, .selectionUnavailable)
    }
}
