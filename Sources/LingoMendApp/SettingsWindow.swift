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
        window.contentView = NSHostingView(rootView: SettingsView(preferences: preferences, onSave: onSave))
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}

private struct SettingsView: View {
    @State var preferences: AppPreferences
    let onSave: @MainActor (AppPreferences) -> Void
    @State private var key = ""
    @State private var removeKey = false
    @State private var status = ""

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
                    Text("阶段 1 仅使用固定本地样例；模型配置在阶段 2 开放。")
                    Toggle("使用配置的模型服务（否则仅本地固定演示）", isOn: $preferences.networkEnabled)
                    Text("开启后，手动请求或已授权应用里的候选触发会把当前段落发给以下服务。不要在敏感文档中启用。没有内置云中转。")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("API Base URL", text: $preferences.provider.baseURL)
                    TextField("模型 ID", text: $preferences.provider.model)
                    SecureField("新 API Key（留空保留已有）", text: $key)
                    Toggle("删除此地址的已存密钥", isOn: $removeKey)
                    Picker("输出格式", selection: $preferences.provider.outputFormat) {
                        Text("JSON object（兼容模式）").tag(ProviderOutputFormat.jsonObject)
                        Text("严格 JSON Schema").tag(ProviderOutputFormat.jsonSchema)
                        Text("仅提示词 JSON").tag(ProviderOutputFormat.promptOnly)
                    }
                    Text("密钥存入 macOS 钥匙串，按服务地址隔离；设置文件不包含密钥。")
                        .font(.caption).foregroundStyle(.secondary)
                }.disabled(true)
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
                    Button("保存设置") { save() }
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
        }.frame(width: 560, height: 650)
    }

    private func appToggle(_ title: String, id: String) -> some View {
        Toggle(title, isOn: Binding(get: { preferences.allowedApplications.contains(id) }, set: {
            if $0 { preferences.allowedApplications.insert(id) } else { preferences.allowedApplications.remove(id) }
        }))
    }

    private func save() {
        do {
            preferences.networkEnabled = false // Stage 1 cannot initiate network requests.
            if preferences.networkEnabled || !key.isEmpty || removeKey { _ = try preferences.provider.endpoint() }
            if removeKey { try ProviderCredentials.remove(for: preferences.provider) }
            else if !key.isEmpty { try ProviderCredentials.save(key, for: preferences.provider) }
            try preferences.persist()
            onSave(preferences)
            key = ""; removeKey = false; status = "已保存"
        } catch { status = providerMessage(error) }
    }
}
