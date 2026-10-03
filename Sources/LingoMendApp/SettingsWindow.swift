import AppKit
import CoachCore
import SwiftUI

@MainActor
final class SettingsWindow {
    private var window: NSWindow?
    func show(preferences: AppPreferences, onSave: @escaping @MainActor (AppPreferences) -> Void) {
        let window = self.window ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 650),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "LingoMend · 设置"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(preferences: preferences, window: window, onSave: onSave))
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}

private struct SettingsView: View {
    @State var preferences: AppPreferences
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
                Section("沉浸式伴随 · 保留你的输入法") {
                    Toggle("启用伴随候选", isOn: $preferences.immersiveEnabled)
                    Text("只监听你勾选的应用。停顿约 1 秒后，当前段落中的中文占位可出现英文候选；继续输入会取消旧候选。")
                        .font(.caption).foregroundStyle(.secondary)
                    appToggle("TextEdit", id: "com.apple.TextEdit")
                    appToggle("Safari（包含其中所有非密码输入框）", id: "com.apple.Safari")
                    Text("⌃⌥↩ 接受候选 · ⌃⌥K 展开学习 · ⌃⌥. 收起。暂不接管 Tab 或中文组词键。")
                        .font(.caption)
                    Toggle("启用实验性跨应用接受", isOn: $preferences.experimentalAcceptance)
                    Text("替换和原生撤销仍待使用验证；关闭时只显示候选，并可主动复制。不会自动写入。")
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
                    Text("保存并开启后，输入体验页及勾选应用的候选触发，会把中文占位和左右各最多 200 个 UTF-16 单位的上下文直接发给下方地址；短句可能全部包含。主动学习会追加候选短语。伴随开启时可自动发出请求。不要用于敏感内容；Safari 授权覆盖整个浏览器，不按网站区分。")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("API Base URL", text: $preferences.provider.baseURL)
                    TextField("模型 ID", text: $preferences.provider.model)
                    SecureField("新 API Key（留空保留已有）", text: $key)
                    Toggle("删除此地址的已存密钥", isOn: $removeKey)
                    Text("JSON object · 关闭思考 · 候选 192 tokens / 12 秒 · 解释 512 tokens / 30 秒\n本轮适配 DeepSeek 参数；更换地址不表示所有兼容服务均支持。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("密钥存入 macOS 钥匙串，按服务地址隔离；设置文件不包含密钥。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("“测试连接”只发送合成样例 This works 轻载条件下.，可能产生少量 API 费用；不读取其他应用或启用伴随。")
                        .font(.caption)
                    HStack {
                        Button(testTask == nil ? "测试连接（合成文本）" : "测试中…") { testConnection() }
                            .disabled(testTask != nil || removeKey)
                        if testTask != nil { Button("取消测试") { cancelTest(); status = "测试已取消" } }
                    }
                }
                Section("写作与学习") {
                    Picker("语境", selection: $preferences.context) {
                        ForEach(WritingContext.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Picker("修正强度", selection: $preferences.correctionLevel) {
                        Text("最小纠错").tag(CorrectionLevel.correct)
                        Text("更自然").tag(CorrectionLevel.natural)
                    }
                    Toggle("本地表达记忆（主动保存，不保存全文）", isOn: $preferences.learningEnabled)
                    Toggle("本地累计统计（阶段 3 开放）", isOn: $preferences.statisticsEnabled).disabled(true)
                }
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
        status = "正在请求合成文本候选…"
        testTask = Task { @MainActor in
            defer { if testEpoch == token { testTask = nil } }
            do {
                let credential = suppliedKey.isEmpty ? try ProviderCredentials.read(for: configuration) : suppliedKey
                let result = try await DeepSeekExpressionProvider(configuration: configuration, apiKey: credential)
                    .candidate(ExpressionRequest(source: "轻载条件下", left: "This works ", right: "."))
                try Task.checkCancellation()
                guard testEpoch == token else { return }
                status = result.map { "连接与格式检查通过：\($0)；尚未保存设置" }
                    ?? "服务返回 abstain；连接成功但未提供候选"
            } catch is CancellationError { }
            catch { if testEpoch == token { status = providerMessage(error) } }
        }
    }
}
