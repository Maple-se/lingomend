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

/// Explicit, TextEdit-only advice; acceptance is a separate user-authorized operation.
@MainActor
private final class LingoMendDelegate: NSObject, NSApplicationDelegate {
    private let reader = MacOSAccessibilityTextReader()
    private let observer = MacOSFocusedTextObserver()
    private var service = SentenceService(preferences: AppPreferences.load())
    private let panel = SentenceCandidatePanel()
    private let notice = RequestNotice()
    private lazy var writer = NativeTextEditPaste(driver: MacOSTextEditPasteDriver(reader: reader))
    private let settingsWindow = SettingsWindow()
    private var preferences = AppPreferences.load()
    private var statusItem: NSStatusItem?
    private var statusLine: NSMenuItem?
    private var trigger: GlobalHotKey?
    private var dismissKey: GlobalHotKey?
    private var acceptKey: GlobalHotKey?
    private var escapeMonitor: Any?
    private var generation: Task<Void, Never>?
    private var epoch = UUID()
    private var hasPreview = false
    private var proposal: SentenceProposal?
    private var activeSnapshot: TextSnapshot?
    private var acceptance: Task<Void, Never>?
    private var quitAfterAcceptance = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "LM"
        let menu = NSMenu()
        let status = NSMenuItem(title: service.modeLabel, action: nil, keyEquivalent: "")
        status.isEnabled = false; statusLine = status; menu.addItem(status)
        let version = NSMenuItem(title: "LingoMend \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development") · TextEdit T2", action: nil, keyEquivalent: "")
        version.isEnabled = false; menu.addItem(version)
        add("设置…", action: #selector(showSettings), to: menu)
        menu.addItem(.separator())
        let hint = NSMenuItem(title: "求助 ⌃⌥L · 接受 ⌃⌥↩ · 取消 Esc / ⌃⌥.", action: nil, keyEquivalent: "")
        hint.isEnabled = false; menu.addItem(hint)
        add("开启辅助功能权限…", action: #selector(requestAccessibility), to: menu)
        menu.addItem(.separator())
        add("退出 LingoMend", action: #selector(quitApp), to: menu)
        item.menu = menu; statusItem = item
        let hotKey = GlobalHotKey { [weak self] in self?.requestAdvice() }
        trigger = hotKey
        if !hotKey.register() { status.title = "⌃⌥L 注册失败；请检查快捷键冲突" }
        observer.onChange = { [weak self] in self?.checkObservedChange() }
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
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard acceptance != nil else { return .terminateNow }
        quitAfterAcceptance = true
        feedback("正在完成粘贴检查和剪贴板清理，随后退出", persistent: true)
        return .terminateLater
    }
    @objc private func showSettings() {
        guard acceptance == nil else { return }
        invalidate()
        settingsWindow.show(preferences: preferences) { [weak self] updated in
            guard let self else { return }
            invalidate(); preferences = updated; service = SentenceService(preferences: updated)
            statusLine?.title = service.modeLabel
        }
    }

    private func feedback(_ text: String, persistent: Bool = false) {
        statusLine?.title = text
        notice.show(text, near: statusItem?.button, persistent: persistent)
    }

    private func checkObservedChange() {
        guard let snapshot = activeSnapshot, acceptance == nil else { return }
        let token = epoch
        Task { @MainActor [weak self] in
            guard let self, epoch == token else { return }
            // AX notifications may repeat without any real source/selection change.
            let current = try? await reader.readFocusedText()
            guard epoch == token, current != snapshot else { return }
            discardChangedPreview()
        }
    }

    private func discardChangedPreview() {
        guard acceptance == nil, generation != nil || hasPreview else { return }
        invalidate()
        statusLine?.title = "输入或焦点已变化；可重新按 ⌃⌥L 求助"
    }

    private func invalidate() {
        epoch = UUID(); generation?.cancel(); generation = nil
        hasPreview = false; proposal = nil; activeSnapshot = nil; panel.hide(); notice.hide()
        unregisterInteractionKeys()
        observer.configure(enabled: false, allowedApplications: [])
    }

    private func unregisterInteractionKeys() {
        dismissKey?.unregister(); dismissKey = nil; acceptKey?.unregister(); acceptKey = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor); self.escapeMonitor = nil }
    }

    private func registerCancellation() {
        let token = epoch
        let key = GlobalHotKey(keyCode: UInt32(kVK_ANSI_Period), identifier: 4) { [weak self] in self?.invalidate() }
        dismissKey = key
        if !key.register() { statusLine?.title = "取消快捷键冲突；可点击候选上的取消" }
        // Observe Escape's key code only, without consuming it or reading typed characters.
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == UInt16(kVK_Escape) else { return }
            MainActor.assumeIsolated {
                guard let self, self.epoch == token else { return }
                self.invalidate()
            }
        }
    }

    private func requestAdvice() {
        guard acceptance == nil else { return }
        invalidate()
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.TextEdit" else {
            feedback("当前阶段请在 TextEdit 中使用 ⌃⌥L"); return
        }
        guard preferences.allowedApplications.contains("com.apple.TextEdit") else {
            feedback("请在设置中勾选 TextEdit，允许按需读取"); return
        }
        // Subscribe only while a requested operation is active, solely to invalidate it.
        // Initial callbacks occur before the task starts and never schedule model work.
        observer.configure(enabled: true, allowedApplications: ["com.apple.TextEdit"])
        let token = epoch
        feedback("正在识别当前表达…", persistent: true)
        registerCancellation()
        generation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.epoch == token {
                    self.generation = nil
                    if !self.hasPreview {
                        self.activeSnapshot = nil; self.unregisterInteractionKeys()
                        self.observer.configure(enabled: false, allowedApplications: [])
                    }
                }
            }
            do {
                let snapshot = try await reader.readFocusedText()
                try Task.checkCancellation()
                guard epoch == token else { return }
                activeSnapshot = snapshot
                let scope = try SentenceScopeResolver().resolve(snapshot)
                let request = try SentenceProposal.request(for: scope)
                statusLine?.title = "\(service.modeLabel) · \(request.intent.label)"
                let advice = try await service.advice(request)
                try Task.checkCancellation()
                guard epoch == token else { return }
                guard try await reader.readFocusedText() == snapshot else { discardChangedPreview(); return }
                let proposal = try SentenceProposal(snapshot: snapshot, scope: scope, advice: advice)
                guard let anchor = try await reader.caretBounds(for: snapshot), epoch == token else {
                    feedback("无法定位光标；请重新把光标放回表达中"); return
                }
                hasPreview = true
                self.proposal = proposal; notice.hide()
                panel.show(proposal, anchor: anchor, onAccept: { [weak self] in self?.accept() },
                    onDismiss: { [weak self] in self?.invalidate() })
                if proposal.advice.status == .suggest {
                    let accept = GlobalHotKey(keyCode: UInt32(kVK_Return), identifier: 2) { [weak self] in self?.accept() }
                    acceptKey = accept
                    if !accept.register() { feedback("接受快捷键冲突；可点击候选上的接受") }
                }
            } catch is CancellationError { }
            catch AccessibilityCaptureError.permissionRequired {
                if epoch == token { feedback("需要辅助功能权限；从 LM 菜单手动开启") }
            } catch let error as SentenceScopeError {
                guard epoch == token else { return }
                switch error {
                case .empty: feedback("当前表达为空；写一点内容后再求助")
                case .multipleSentences: feedback("当前支持一句；请将光标放进一句或缩小选区")
                case .tooLong: feedback("当前句超过 600 UTF-16 单位；请选择较短的独立句子")
                case .invalidRange: feedback("无法确认范围；请重新放置光标或选区")
                }
            } catch SentenceInputError.unsupported {
                if epoch == token { feedback("当前支持中英文文字表达；代码、公式和地址暂不处理") }
            } catch {
                guard epoch == token else { return }
                feedback(error is CoachingProviderError || error is CredentialError
                    ? providerMessage(error) : "当前编辑器暂不支持读取或定位；请检查光标位置")
            }
        }
    }

    private func accept() {
        guard acceptance == nil, let proposal, proposal.advice.status == .suggest else { return }
        let plan: SentenceEditPlan
        do { plan = try SentenceEditPlan(original: proposal.snapshot, scope: proposal.scope, replacement: proposal.advice.replacement) }
        catch { invalidate(); feedback("无法确认编辑范围；请重新求助"); return }
        // Remove preview and its keys before starting; repeated clicks cannot reuse it.
        invalidate()
        feedback("正在接受建议…", persistent: true)
        acceptance = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                acceptance = nil
                if quitAfterAcceptance { NSApp.reply(toApplicationShouldTerminate: true) }
            }
            do {
                let result = try await writer.accept(plan)
                if result.clipboard == .failed { feedback("文本已更新，但剪贴板恢复失败；请检查剪贴板") }
                else if !result.caretPositioned { feedback("文本已更新；光标位置未确认，请检查后继续写作") }
                else { feedback("已接受 · 在 TextEdit 按 ⌘Z 可撤销") }
            } catch NativePasteError.resultUnconfirmed {
                feedback("粘贴结果未确认；请检查原文，必要时在 TextEdit 按 ⌘Z。不会自动重试")
            } catch NativePasteError.clipboardRestorationFailed(let dispatched) {
                feedback(dispatched ? "已发送粘贴，但剪贴板恢复失败；请检查原文和剪贴板"
                    : "未发送粘贴，但剪贴板恢复失败；请检查剪贴板")
            } catch NativePasteError.clipboardUnavailable {
                feedback("无法可靠保存剪贴板内容；未发送粘贴，请换用普通文本剪贴板后重试")
            } catch NativePasteError.formatUnavailable, NativePasteError.unsupportedFormat {
                feedback("当前格式无法可靠保持；未发送粘贴，请先在普通文本或基础富文本中体验")
            } catch NativePasteError.modifiersHeld {
                feedback("请松开快捷键后重新求助；未发送粘贴")
            } catch {
                feedback("原文、焦点、选区或剪贴板已变化，或控件不支持；未发送粘贴，请重新求助")
            }
        }
    }
}
