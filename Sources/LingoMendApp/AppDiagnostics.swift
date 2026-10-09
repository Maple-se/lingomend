import AppKit
import CoachCore
import DiagnosticsCore
import PlatformBridge
import SwiftUI

/// Independent preferences: adding diagnostics never changes the provider settings schema.
@MainActor
final class AppDiagnostics: ObservableObject {
    let channel: BuildChannel
    let recorder: LocalDiagnostics
    private let defaults: UserDefaults
    @Published private(set) var enabled: Bool
    @Published private(set) var busy = false
    @Published private(set) var state: DiagnosticsStatus = .off

    init(bundle: Bundle = .main, defaults: UserDefaults = .standard,
         channel: BuildChannel? = nil, directory: URL? = nil) {
        let channel = channel ?? BuildChannel(metadata: bundle.object(forInfoDictionaryKey: "LingoMendBuildChannel") as? String)
        self.channel = channel; self.defaults = defaults
        self.enabled = (defaults.object(forKey: channel.preferenceKey) as? Bool) ?? channel.defaultEnabled
        self.recorder = LocalDiagnostics(channel: channel,
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String, directory: directory)
    }
    func start() async { await apply(enabled) }
    func setEnabled(_ value: Bool) async {
        guard !busy else { return }
        defaults.set(value, forKey: channel.preferenceKey)
        await apply(value)
    }
    func reset() async {
        guard !busy else { return }
        defaults.removeObject(forKey: channel.preferenceKey)
        await apply(channel.defaultEnabled)
    }
    private func apply(_ value: Bool) async {
        busy = true; enabled = value
        await recorder.setEnabled(value)
        refresh(); busy = false
    }
    func clear() async {
        guard !busy else { return }
        busy = true; await recorder.clear(); refresh(); busy = false
    }
    func refresh() { state = recorder.status }
    func openDirectory() {
        guard FileManager.default.fileExists(atPath: recorder.directory.path) else { return }
        NSWorkspace.shared.open(recorder.directory)
    }
    var statusLabel: String {
        switch state {
        case .off: "已关闭（已有文件保留）"
        case .starting: "正在开启"
        case .active: "正在记录 · 仅本地"
        case .unavailable: "日志存储不可用；写作功能继续运行，可关闭后重开"
        }
    }
}

/// Error classification only: never forward descriptions, associated strings or response bodies.
func diagnosticReason(_ error: Error) -> DiagnosticReason {
    if error is CancellationError { return .userCancelled }
    if error is CredentialError { return .credentials }
    if let error = error as? CoachingProviderError {
        switch error {
        case .invalidConfiguration, .insecureEndpoint: return .configuration
        case .emptyInput: return .empty
        case .inputTooLarge: return .tooLong
        case .unauthorized: return .unauthorized
        case .rateLimited: return .rateLimited
        case .httpStatus: return .http
        case .network: return .network
        case .timedOut: return .timedOut
        case .responseTooLarge: return .responseTooLarge
        case .invalidResponse: return .invalidResponse
        case .incompleteResponse: return .incompleteResponse
        case .refused: return .refused
        }
    }
    if let error = error as? SentenceScopeError {
        switch error { case .invalidRange: return .invalidRange; case .empty: return .empty
        case .multipleSentences: return .multipleSentences; case .tooLong: return .tooLong }
    }
    if case AccessibilityCaptureError.permissionRequired = error { return .permissionRequired }
    if error is SentenceInputError { return .unsupportedInput }
    return .captureUnavailable
}

func diagnosticAdviceOutcome(_ advice: SentenceAdvice) -> DiagnosticOutcome {
    switch advice.status {
    case .suggest: .suggest
    case .unchanged: .unchanged
    case .clarify: .clarify
    case .unsupported: .unsupported
    }
}
