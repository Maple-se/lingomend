import AppKit
import ApplicationServices
import Carbon
import CoachCore
import MVPFlow
import PlatformBridge

@main
enum LingoMendApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = LingoMendDelegate()
        app.delegate = delegate
        app.run()
    }
}

/// T1: explicit, TextEdit-only advice. No automatic generation or external writes.
@MainActor
private final class LingoMendDelegate: NSObject, NSApplicationDelegate {
    private let reader = MacOSAccessibilityTextReader()
    private let observer = MacOSFocusedTextObserver()
    private var service = SentenceService(preferences: AppPreferences.load())
    private let panel = SentenceCandidatePanel()
    private let settingsWindow = SettingsWindow()
    private var preferences = AppPreferences.load()
    private var statusItem: NSStatusItem?
    private var statusLine: NSMenuItem?
    private var trigger: GlobalHotKey?
    private var dismissKey: GlobalHotKey?
    private var generation: Task<Void, Never>?
    private var epoch = UUID()
    private var hasPreview = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "LM"
        let menu = NSMenu()
        let status = NSMenuItem(title: service.modeLabel, action: nil, keyEquivalent: "")
        status.isEnabled = false; statusLine = status; menu.addItem(status)
        add("设置…", action: #selector(showSettings), to: menu)
        menu.addItem(.separator())
        let hint = NSMenuItem(title: "TextEdit 求助 ⌃⌥L · 收起 ⌃⌥. · T1 只读", action: nil, keyEquivalent: "")
        hint.isEnabled = false; menu.addItem(hint)
        add("开启辅助功能权限…", action: #selector(requestAccessibility), to: menu)
        menu.addItem(.separator())
        add("退出 LingoMend", action: #selector(quitApp), to: menu)
        item.menu = menu; statusItem = item
        let hotKey = GlobalHotKey { [weak self] in self?.requestAdvice() }
        trigger = hotKey
        if !hotKey.register() { status.title = "⌃⌥L 注册失败；请检查快捷键冲突" }
        observer.onChange = { [weak self] in self?.discardChangedPreview() }
        observer.onUnavailable = { [weak self] in self?.discardChangedPreview() }
        reader.allowedApplications = ["com.apple.TextEdit"]
    }

    private func add(_ title: String, action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self; menu.addItem(item)
    }
    @objc private func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
    @objc private func quitApp() { NSApp.terminate(nil) }
    @objc private func showSettings() {
        invalidate()
        settingsWindow.show(preferences: preferences) { [weak self] updated in
            guard let self else { return }
            invalidate(); preferences = updated; service = SentenceService(preferences: updated)
            statusLine?.title = service.modeLabel
        }
    }

    private func discardChangedPreview() {
        guard generation != nil || hasPreview else { return }
        invalidate()
        statusLine?.title = "输入或焦点已变化；可重新按 ⌃⌥L 求助"
    }

    private func invalidate() {
        epoch = UUID(); generation?.cancel(); generation = nil
        hasPreview = false; panel.hide(); dismissKey?.unregister(); dismissKey = nil
        observer.configure(enabled: false, allowedApplications: [])
    }

    private func requestAdvice() {
        invalidate()
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.TextEdit" else {
            statusLine?.title = "当前阶段请在 TextEdit 中使用 ⌃⌥L"; return
        }
        guard preferences.allowedApplications.contains("com.apple.TextEdit") else {
            statusLine?.title = "请在设置中勾选 TextEdit，允许按需读取"; return
        }
        // Subscribe only while a requested operation is active, solely to invalidate it.
        // Initial callbacks occur before the task starts and never schedule model work.
        observer.configure(enabled: true, allowedApplications: ["com.apple.TextEdit"])
        let token = epoch
        statusLine?.title = "正在识别当前表达…"
        generation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.epoch == token {
                    self.generation = nil
                    if !self.hasPreview { self.observer.configure(enabled: false, allowedApplications: []) }
                }
            }
            do {
                let snapshot = try await reader.readFocusedText()
                try Task.checkCancellation()
                let scope = try SentenceScopeResolver().resolve(snapshot)
                let request = try SentenceProposal.request(for: scope)
                statusLine?.title = "\(service.modeLabel) · \(request.intent.label)"
                let advice = try await service.advice(request)
                try Task.checkCancellation()
                guard epoch == token, try await reader.readFocusedText() == snapshot else { return }
                let proposal = try SentenceProposal(snapshot: snapshot, scope: scope, advice: advice)
                guard let anchor = try await reader.caretBounds(for: snapshot), epoch == token else {
                    statusLine?.title = "无法定位光标；请重新把光标放回表达中"; return
                }
                hasPreview = true
                panel.show(proposal, anchor: anchor, onDismiss: { [weak self] in self?.invalidate() })
                let key = GlobalHotKey(keyCode: UInt32(kVK_ANSI_Period), identifier: 4) { [weak self] in self?.invalidate() }
                dismissKey = key
                if !key.register() { statusLine?.title = "收起快捷键冲突；可点击候选上的收起" }
            } catch is CancellationError { }
            catch AccessibilityCaptureError.permissionRequired {
                if epoch == token { statusLine?.title = "需要辅助功能权限；从 LM 菜单手动开启" }
            } catch let error as SentenceScopeError {
                guard epoch == token else { return }
                switch error {
                case .empty: statusLine?.title = "当前表达为空；写一点内容后再求助"
                case .multipleSentences: statusLine?.title = "当前支持一句；请将光标放进一句或缩小选区"
                case .tooLong: statusLine?.title = "当前句超过 600 UTF-16 单位；请选择较短的独立句子"
                case .invalidRange: statusLine?.title = "无法确认范围；请重新放置光标或选区"
                }
            } catch SentenceInputError.unsupported {
                if epoch == token { statusLine?.title = "当前支持中英文文字表达；代码、公式和地址暂不处理" }
            } catch {
                guard epoch == token else { return }
                statusLine?.title = error is CoachingProviderError || error is CredentialError
                    ? providerMessage(error) : "当前编辑器暂不支持读取或定位；请检查光标位置"
            }
        }
    }
}
