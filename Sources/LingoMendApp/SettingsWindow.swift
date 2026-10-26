import AppKit
import ApplicationServices
import CoachCore
import SwiftUI
import DiagnosticsCore

@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var hasUnsavedChanges = false
    func show(preferences: AppPreferences, diagnostics: AppDiagnostics, onSave: @escaping @MainActor (AppPreferences) -> Void) {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = self.window ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "LingoMend · 设置"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 680, height: 500)
        window.delegate = self
        hasUnsavedChanges = false
        window.contentView = NSHostingView(rootView: SettingsView(preferences: preferences, diagnostics: diagnostics,
            window: window, onSave: onSave, onDirtyChange: { [weak self] in self?.hasUnsavedChanges = $0 }))
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard hasUnsavedChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "放弃未保存的设置？"
        alert.informativeText = "修改尚未保存。"
        alert.addButton(withTitle: "继续编辑")
        alert.addButton(withTitle: "放弃修改")
        let discard = alert.runModal() == .alertSecondButtonReturn
        if discard { hasUnsavedChanges = false }
        return discard
    }
}

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "常规"
    case access = "访问与应用"
    case service = "模型服务"
    case diagnostics = "本地诊断"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .access: "hand.raised"
        case .service: "network"
        case .diagnostics: "waveform.path.ecg"
        }
    }
}

private struct SettingsView: View {
    @State var preferences: AppPreferences
    @ObservedObject var diagnostics: AppDiagnostics
    let window: NSWindow
    let onSave: @MainActor (AppPreferences) -> Void
    let onDirtyChange: @MainActor (Bool) -> Void
    @State private var baseline: AppPreferences?
    @State private var selectedTab: SettingsTab? = .general
    @State private var accessibilityTrusted = AXIsProcessTrusted()
    @State private var key = ""
    @State private var removeKey = false
    @State private var confirmRemoveKey = false
    @State private var status = ""
    @State private var testTask: Task<Void, Never>?
    @State private var testEpoch = UUID()

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                ForEach(SettingsTab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab.symbol).tag(tab)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            VStack(spacing: 0) {
                Form {
                    switch selectedTab ?? .general {
                    case .general: generalSection
                    case .access: accessSection
                    case .service: serviceSection
                    case .diagnostics: DiagnosticsSettingsSection(diagnostics: diagnostics)
                    }
                }
                .formStyle(.grouped)
                Divider()
                HStack(spacing: 12) {
                    Text(status.isEmpty ? "修改设置后点“保存设置”" : status)
                        .font(.callout).foregroundStyle(.secondary)
                        .accessibilityAddTraits(.updatesFrequently)
                    Spacer()
                    Button("关闭") { window.performClose(nil) }.frame(minHeight: 44)
                    Button("保存设置") { save() }
                        .buttonStyle(.borderedProminent)
                        .frame(minHeight: 44)
                        .disabled(testTask != nil)
                }
                .padding(.horizontal, 20).padding(.vertical, 8)
            }
        }
        .frame(minWidth: 680, minHeight: 500)
        .onAppear {
            baseline = preferences
            accessibilityTrusted = AXIsProcessTrusted()
        }
        .onChange(of: preferences) { _, _ in
            cancelTest(); status = "设置有改动，尚未保存"; updateDirty()
        }
        .onChange(of: preferences.provider.baseURL) { _, _ in
            cancelTest(); key = ""; removeKey = false
            status = "地址已更改；请填写该地址的密钥，或留空使用其已有密钥"
            updateDirty()
        }
        .onChange(of: key) { _, _ in cancelTest(); updateDirty() }
        .onChange(of: removeKey) { _, _ in cancelTest(); updateDirty() }
        .onDisappear { cancelTest(); key = "" }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: window)) { _ in
            cancelTest(); key = ""
        }
        .confirmationDialog("删除此服务地址的已存密钥？", isPresented: $confirmRemoveKey) {
            Button("删除密钥", role: .destructive) {
                preferences.networkEnabled = false
                removeKey = true
                key = ""
                status = "密钥将在保存设置时删除；模型服务已关闭"
            }
        } message: {
            Text("删除后需要重新输入密钥才能使用模型服务。其他地址的密钥不受影响。")
        }
    }

    private var generalSection: some View {
        Section("按需使用") {
            Text("先在原编辑器写作。按 ⌃⌥L 获取当前句或选区建议；先核对原文与修改，再明确接受。")
                .font(.body)
            Text("按 ⌃⌥D 阅读选中的英文词句与语境。阅读解释不会修改原文。")
                .font(.body)
            Text("候选出现后可按 ⌃⌥↩ 接受，按 Esc 或 ⌃⌥. 收起；在原编辑器按 ⌘Z 撤销。普通 Return、Tab 与输入法操作仍交给原编辑器。")
                .font(.callout).foregroundStyle(.secondary)
            Text(preferences.networkEnabled ? "模型服务已开启；每次按快捷键会发起按需请求。" : "当前使用固定本地样例；其他表达需开启模型服务。")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var accessSection: some View {
        Group {
            Section("辅助功能权限") {
                Label(accessibilityTrusted ? "已授权" : "需要授权",
                      systemImage: accessibilityTrusted ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(accessibilityTrusted ? .green : .orange)
                Text("LingoMend 只在你按下快捷键后读取前台文字；接受前会重新检查原文、选区与焦点。")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("打开系统设置") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Button("重新检查") { accessibilityTrusted = AXIsProcessTrusted() }
                }
            }
            Section("允许的应用") {
                appToggle("TextEdit", id: "com.apple.TextEdit")
                Toggle("允许其他应用中的按需写作与阅读", isOn: $preferences.globalAccessEnabled)
                Text("关闭时仅在上方勾选的应用中使用。开启后，其他应用的可访问编辑区和选区也可响应快捷键。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("接受与隐私") {
                Text("接受时临时借用剪贴板执行一次原生粘贴；在仍属本次操作时恢复。剪贴板历史工具可能记录临时内容。")
                    .font(.callout)
                Text("基础富文本可保留常见字体和样式；复杂格式与不同编辑器的撤销行为需要在原应用核对。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var serviceSection: some View {
        Group {
            Section("连接") {
                HStack {
                    Text("DeepSeek · Chat Completions")
                    Spacer()
                    Button("恢复 DeepSeek 预设") {
                        preferences.provider = DeepSeekExpressionProvider.preset
                        preferences.networkEnabled = false
                    }
                }
                Toggle("使用配置的模型服务", isOn: $preferences.networkEnabled)
                TextField("API Base URL", text: $preferences.provider.baseURL)
                TextField("模型 ID", text: $preferences.provider.model)
                SecureField("新 API Key（留空保留已有）", text: $key)
                Button("删除当前地址的已存密钥…", role: .destructive) { confirmRemoveKey = true }
                    .disabled(removeKey)
                if removeKey { Text("已标记删除，保存设置后生效").foregroundStyle(.orange) }
                Text("密钥存于 macOS 钥匙串，按完整服务地址隔离；设置文件不含密钥。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("请求范围与费用") {
                Text("写作发送当前句（最多 600 个 UTF-16 单位）或明确选中的短段落（最多 1200）；阅读发送选区及实际取得的附近语境（合计最多 2000）。")
                    .font(.callout)
                Text("只在按下快捷键后请求，不自动重试。每次请求可能产生费用；服务失败不会退回固定样例。")
                    .font(.callout).foregroundStyle(.secondary)
                Text("“测试连接”只发送合成句子 This works 轻载条件下.；不读取其他应用，也不保存网络开关。")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button(testTask == nil ? "测试连接（合成文本）" : "测试中…") { testConnection() }
                        .disabled(testTask != nil || removeKey)
                    if testTask != nil { Button("取消测试") { cancelTest(); status = "测试已取消" } }
                }
            }
        }
    }

    private func updateDirty() {
        guard let baseline else { return }
        onDirtyChange(preferences != baseline || !key.isEmpty || removeKey)
    }

    private func appToggle(_ title: String, id: String) -> some View {
        Toggle(title, isOn: Binding(get: { preferences.allowedApplications.contains(id) }, set: {
            if $0 { preferences.allowedApplications.insert(id) } else { preferences.allowedApplications.remove(id) }
        }))
    }

    private func save() {
        do {
            preferences.provider.outputFormat = .jsonObject
            if preferences.networkEnabled || !key.isEmpty || removeKey { _ = try preferences.provider.endpoint() }
            if preferences.networkEnabled {
                guard !removeKey else { status = "删除密钥前请关闭模型服务"; return }
                if key.isEmpty {
                    guard !(try ProviderCredentials.read(for: preferences.provider)).isEmpty else {
                        status = "请先填写此服务地址的 API Key"; return
                    }
                }
            }
            if removeKey { try ProviderCredentials.remove(for: preferences.provider) }
            else if !key.isEmpty { try ProviderCredentials.save(key, for: preferences.provider) }
            try preferences.persist()
            onSave(preferences)
            key = ""; removeKey = false; baseline = preferences
            onDirtyChange(false)
            status = "已保存"
        } catch { status = providerMessage(error) }
    }

    private func cancelTest() {
        testEpoch = UUID(); testTask?.cancel(); testTask = nil
    }

    private func testConnection() {
        cancelTest()
        let token = testEpoch
        var configuration = preferences.provider
        configuration.outputFormat = .jsonObject
        let suppliedKey = key
        let operation = UUID(), start = ContinuousClock.now
        diagnostics.recorder.record(DiagnosticEvent(.connectionTestStarted, mode: .network), operation: operation)
        status = "正在请求合成文本候选…"
        testTask = Task { @MainActor in
            defer { if testEpoch == token { testTask = nil } }
            do {
                let credential = suppliedKey.isEmpty ? try ProviderCredentials.read(for: configuration) : suppliedKey
                let result = try await DeepSeekSentenceProvider(configuration: configuration, apiKey: credential)
                    .advice(SentenceRequest(target: "This works 轻载条件下."))
                try Task.checkCancellation()
                diagnostics.recorder.record(DiagnosticEvent(.connectionTestCompleted,
                    outcome: diagnosticAdviceOutcome(result), mode: .network,
                    durationMS: diagnosticMilliseconds(since: start)), operation: operation)
                guard testEpoch == token else { return }
                status = result.status == .suggest ? "连接与格式检查通过：\(result.replacement)；尚未保存设置"
                    : "连接成功：\(result.status.rawValue)；\(result.message)"
            } catch {
                let code: Int? = if case CoachingProviderError.httpStatus(let code) = error { code } else { nil }
                diagnostics.recorder.record(DiagnosticEvent(.connectionTestFailed,
                    level: error is CancellationError ? .info : .error,
                    outcome: error is CancellationError ? .cancelled : .failed,
                    reason: diagnosticReason(error), mode: .network,
                    durationMS: diagnosticMilliseconds(since: start), httpStatus: code), operation: operation)
                if testEpoch == token, !(error is CancellationError) { status = providerMessage(error) }
            }
        }
    }
}

private struct DiagnosticsSettingsSection: View {
    @ObservedObject var diagnostics: AppDiagnostics
    @State private var confirmClear = false
    var body: some View {
        Section("本地开发诊断") {
            Toggle("记录本地调试日志（立即生效）", isOn: Binding(
                get: { diagnostics.enabled },
                set: { value in Task { await diagnostics.setEnabled(value) } }))
                .disabled(diagnostics.busy)
            Text("渠道：\(diagnostics.channel.rawValue) · 默认\(diagnostics.channel.defaultEnabled ? "开启" : "关闭")\n\(diagnostics.statusLabel)")
                .font(.caption).foregroundStyle(.secondary)
            Text("仅记录固定流程事件、随机操作编号、长度、耗时和错误分类。原文、建议、提示词、剪贴板、密钥及网络正文不入日志。不上传；最多 5 个 1 MiB 文件，保留 7 天。关闭不删除已有文件。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("打开日志目录") { diagnostics.openDirectory() }
                Button("清空日志…") { confirmClear = true }.disabled(diagnostics.busy)
                Button("恢复渠道默认") { Task { await diagnostics.reset() } }.disabled(diagnostics.busy)
            }
            Text("开关独立保存，无需点“保存设置”。清空只删除本模块日志；开启时会生成新的会话头。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog("永久删除当前渠道的本地日志？", isPresented: $confirmClear) {
            Button("清空日志（不可恢复）", role: .destructive) { Task { await diagnostics.clear() } }
        }
    }
}
