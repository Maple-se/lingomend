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
    if let error = error as? ReadingScopeError {
        switch error { case .emptySelection: return .empty; case .tooLong: return .tooLong
        case .invalidRange: return .invalidRange }
    }
    if let error = error as? AccessibilityCaptureError {
        return error.diagnosticReason
    }
    if let error = error as? AccessibilityReplacementError {
        switch error {
        case .explicitSelectionRequired, .invalidReplacement: return .invalidRange
        case .unsupportedApplication: return .unsupportedApplication
        case .staleCapture: return .stale
        case .targetUnavailable: return .focusedElementUnavailable
        case .writeUnsupported: return .writeUnsupported
        case .writeFailed: return .eventUnavailable
        case .verificationFailed: return .resultUnconfirmed
        }
    }
    if error is SentenceInputError { return .unsupportedInput }
    return .captureUnavailable
}

func clipboardRefusalMessage(_ reason: ClipboardDiagnostic.Reason?) -> String {
    switch reason {
    case .byteLimit:
        "剪贴板备份超过安全大小上限；未发送粘贴。可先保存当前复制内容，再复制少量普通文本后重新求助"
    case .promisedData:
        "剪贴板含无法可靠恢复的延迟文件数据；未发送粘贴。可先完成当前复制操作，再复制普通文本后重新求助"
    case .itemLimit, .typeLimit, .emptyTypes, .itemsUnavailable, .dataUnavailable:
        "无法完整备份当前剪贴板；未发送粘贴。可先保存当前复制内容，再复制普通文本后重新求助"
    case .payloadUnavailable, .writeFailed:
        "临时写入剪贴板失败；未发送粘贴。请稍后重新求助"
    case nil:
        "剪贴板暂不可用；未发送粘贴。请稍后重新求助"
    }
}

func diagnosticAdviceOutcome(_ advice: SentenceAdvice) -> DiagnosticOutcome {
    switch advice.status {
    case .suggest: .suggest
    case .unchanged: .unchanged
    case .clarify: .clarify
    case .unsupported: .unsupported
    }
}
