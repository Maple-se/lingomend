import AppKit
import CoachCore
import SwiftUI
import DiagnosticsCore

@MainActor
final class SettingsWindow {
    private var window: NSWindow?
    func show(preferences: AppPreferences, diagnostics: AppDiagnostics, onSave: @escaping @MainActor (AppPreferences) -> Void) {
        let window = self.window ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 650),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "LingoMend · 设置"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(preferences: preferences, diagnostics: diagnostics, window: window, onSave: onSave))
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}

private struct SettingsView: View {
    @State var preferences: AppPreferences
    @ObservedObject var diagnostics: AppDiagnostics
    let window: NSWindow
    let onSave: @MainActor (AppPreferences) -> Void
    @State private var key = ""
    @State private var removeKey = false
    @State private var status = ""
    @State private var testTask: Task<Void, Never>?
    @State private var testEpoch = UUID()

    var body: some View {
        ScrollView {
            Form {
                Section("按需表达帮助 · TextEdit T2") {
                    Text("后台安静运行。在 TextEdit 按 ⌃⌥L：无选区读取当前句，有选区用所在句理解并限制在选区内。先看建议和变化，明确接受才修改原文。")
                        .font(.caption).foregroundStyle(.secondary)
                    appToggle("TextEdit", id: "com.apple.TextEdit")
                    Text("⌃⌥↩ 接受；Esc / ⌃⌥. 取消。在 TextEdit 用 ⌘Z 原生撤销。输入或焦点变化使候选失效；不接管普通 Return、Tab 或输入法组词键。")
                        .font(.caption)
                    Text("接受时临时借用系统剪贴板执行一次原生粘贴，保存原内容并在仍属本次操作时恢复；检测到新复制内容则保留它。无法保存剪贴板或保持格式时拒绝粘贴。剪贴板历史工具可能记录临时内容。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("本轮支持字体、字号、粗体、斜体、颜色与下划线等基础样式；附件、链接及复杂布局不在支持范围。真实 TextEdit 的写回、撤销和格式保持需试用验收。按需学习在 T3 接入。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("建议服务") {
                    HStack {
                        Text("DeepSeek · OpenAI-compatible Chat Completions")
                        Button("恢复 DeepSeek 预设") {
                            preferences.provider = DeepSeekExpressionProvider.preset
                            preferences.networkEnabled = false
                        }
                    }
                    Toggle("使用配置的模型服务（否则仅本地固定演示）", isOn: $preferences.networkEnabled)
                    Text("保存并开启后，手动求助会把当前句的目标与只读左右语境发给下方地址，合计最多 600 个 UTF-16 单位；超长句不截断发送。系统桥接在本地可能读取整个聚焦控件，再定位句子。不发送整篇、路径、应用身份或历史；不主动联网分析。")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("API Base URL", text: $preferences.provider.baseURL)
                    TextField("模型 ID", text: $preferences.provider.model)
                    SecureField("新 API Key（留空保留已有）", text: $key)
                    Toggle("删除此地址的已存密钥", isOn: $removeKey)
                    Text("JSON object · 关闭思考 · 句子建议 640 tokens / 15 秒\n候选按需请求，不自动重试；每次触发可能产生费用。当前使用 DeepSeek 参数。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("密钥存入 macOS 钥匙串，按服务地址隔离；设置文件不包含密钥。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("“测试连接”只发送合成句子 This works 轻载条件下.，可能产生少量 API 费用；不读取 TextEdit，也不保存网络开关。")
                        .font(.caption)
                    HStack {
                        Button(testTask == nil ? "测试连接（合成文本）" : "测试中…") { testConnection() }
                            .disabled(testTask != nil || removeKey)
                        if testTask != nil { Button("取消测试") { cancelTest(); status = "测试已取消" } }
                    }
                }
                Section("写作与学习 · 后续阶段") {
                    Text("当前按原意生成自然英文，修正必要的语法和搭配，保留作者语气、观点与技术信息。风格切换和学习收藏将在后续阶段开放。")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("语境", selection: $preferences.context) {
                        ForEach(WritingContext.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.disabled(true)
                    Picker("修正强度", selection: $preferences.correctionLevel) {
                        Text("最小纠错").tag(CorrectionLevel.correct)
                        Text("更自然").tag(CorrectionLevel.natural)
                    }.disabled(true)
                    Toggle("本地表达记忆（主动保存，不保存全文）", isOn: $preferences.learningEnabled).disabled(true)
                    Toggle("本地累计统计（阶段 3 开放）", isOn: $preferences.statisticsEnabled).disabled(true)
                }
                DiagnosticsSettingsSection(diagnostics: diagnostics)
                HStack {
                    Button("保存设置") { save() }.disabled(testTask != nil)
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
        }.frame(width: 560, height: 650)
            .onChange(of: preferences) { _, _ in cancelTest(); status = "设置有改动，尚未保存" }
            .onChange(of: preferences.provider.baseURL) { _, _ in
                cancelTest(); key = ""; removeKey = false
                status = "地址已更改；请填写该地址的密钥，或留空使用其已有密钥"
            }
            .onChange(of: key) { _, _ in cancelTest() }
            .onChange(of: removeKey) { _, _ in cancelTest() }
            .onDisappear { cancelTest(); key = "" }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: window)) { _ in
                cancelTest(); key = ""
            }
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
            key = ""; removeKey = false; status = "已保存"
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
