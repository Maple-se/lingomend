import AppKit
import ApplicationServices
import Carbon
import CoachCore
import LearningCore
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

@MainActor
private final class LingoMendDelegate: NSObject, NSApplicationDelegate {
    private let reader = MacOSAccessibilityTextReader()
    private let observer = MacOSFocusedTextObserver()
    private var service = ExpressionService(preferences: AppPreferences.load())
    private let learning = LearningPresenter()
    private let candidatePanel = InlineCandidatePanel()
    private let settingsWindow = SettingsWindow()
    private let demoWindow = DemoInputWindow()
    private var preferences = AppPreferences.load()
    private var statusItem: NSStatusItem?
    private var statusLine: NSMenuItem?
    private var hotKeys: [GlobalHotKey] = []
    private var candidateKeys: [GlobalHotKey] = []
    private var generation: Task<Void, Never>?
    private var epoch = UUID()
    private var proposal: InlineProposal?
    private var lastAutomaticRequest = Date.distantPast
    private var suppressedSnapshot: TextSnapshot?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "LM"
        let menu = NSMenu()
        let status = NSMenuItem(title: service.modeLabel, action: nil, keyEquivalent: "")
        status.isEnabled = false; statusLine = status; menu.addItem(status)
        add("打开输入体验", action: #selector(showInputExperience), to: menu)
        add("设置…", action: #selector(showSettings), to: menu)
        menu.addItem(.separator())
        let hint = NSMenuItem(title: "手动候选 ⌃⌥L · 接受 ⌃⌥↩ · 学习 ⌃⌥K", action: nil, keyEquivalent: "")
        hint.isEnabled = false; menu.addItem(hint)
        add("开启辅助功能权限…", action: #selector(requestAccessibility), to: menu)
        add("暂停伴随模式", action: #selector(pauseImmersion), to: menu)
        menu.addItem(.separator())
        add("退出 LingoMend", action: #selector(quitApp), to: menu)
        item.menu = menu; statusItem = item
        let trigger = GlobalHotKey { [weak self] in self?.schedule(automatic: false) }
        hotKeys = [trigger]
        if !trigger.register() { status.title = "⌃⌥L 注册失败；请检查快捷键冲突" }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.demoWindow.hasCandidate,
                      event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.control, .option] else { return false }
                switch Int(event.keyCode) {
                case kVK_Return: self.demoWindow.accept()
                case kVK_ANSI_K: self.demoWindow.learn()
                case kVK_ANSI_Period: self.demoWindow.dismiss()
                default: return false
                }
                return true
            }
            return consumed ? nil : event
        }
        observer.onChange = { [weak self] in self?.schedule(automatic: true) }
        observer.onUnavailable = { [weak self] in self?.invalidate() }
        configureObserver()
    }

    private func add(_ title: String, action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self; menu.addItem(item)
    }

    @objc private func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
    @objc private func quitApp() { NSApp.terminate(nil) }
    @objc private func showInputExperience() { invalidate(); demoWindow.show(service: service) }
    @objc private func showSettings() {
        invalidate()
        learning.cancel()
        demoWindow.suspend()
        settingsWindow.show(preferences: preferences) { [weak self] updated in
            guard let self else { return }
            preferences = updated
            service = ExpressionService(preferences: updated)
            demoWindow.configure(service: service)
            configureObserver()
        }
    }
    @objc private func pauseImmersion() {
        preferences.immersiveEnabled = false
        try? preferences.persist()
        configureObserver()
        statusLine?.title = "伴随已暂停 · 输入体验：\(service.modeLabel)"
    }

    private func configureObserver() {
        invalidate()
        reader.allowedApplications = preferences.allowedApplications
        observer.configure(enabled: preferences.immersiveEnabled, allowedApplications: preferences.allowedApplications)
        statusLine?.title = "\(service.modeLabel) · \(preferences.immersiveEnabled ? "伴随已启用" : "伴随关闭")"
    }

    private func invalidate() {
        epoch = UUID(); generation?.cancel(); generation = nil
        proposal = nil; candidatePanel.hide()
        for key in candidateKeys { key.unregister() }
        candidateKeys = []
    }

    private func schedule(automatic: Bool) {
        invalidate()
        if !automatic { suppressedSnapshot = nil }
        guard let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              preferences.allowedApplications.contains(app),
              !automatic || preferences.immersiveEnabled else {
            if !automatic { statusLine?.title = "请先在设置中勾选目标应用，或打开本地输入体验" }
            return
        }
        let token = epoch
        generation = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if automatic { try await Task.sleep(for: .milliseconds(1_000)) }
                guard self.epoch == token else { return }
                let snapshot = try await self.reader.readFocusedText()
                guard self.epoch == token, self.preferences.allowedApplications.contains(snapshot.applicationIdentifier),
                      snapshot != self.suppressedSnapshot,
                      let placeholder = InlinePlaceholderResolver().resolve(snapshot) else { return }
                if automatic {
                    let remaining = 3 - Date().timeIntervalSince(self.lastAutomaticRequest)
                    if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
                    guard self.epoch == token, try await self.reader.readFocusedText() == snapshot else { return }
                    self.lastAutomaticRequest = Date()
                }
                guard let request = InlineProposal.request(for: placeholder, context: self.preferences.context,
                    correctionLevel: self.preferences.correctionLevel) else { return }
                let service = self.service
                guard let replacement = try await service.candidate(request) else {
                    if self.epoch == token { self.statusLine?.title = "\(service.modeLabel) · 此表达暂无可靠候选" }
                    return
                }
                try Task.checkCancellation()
                guard self.epoch == token, try await self.reader.readFocusedText() == snapshot,
                      let proposal = InlineProposal(snapshot: snapshot, placeholder: placeholder, replacement: replacement),
                      let anchor = try await self.reader.caretBounds(for: snapshot), self.epoch == token else { return }
                self.proposal = proposal
                self.statusLine?.title = service.modeLabel
                self.candidatePanel.show(text: proposal.replacement, anchor: anchor,
                    canAccept: self.preferences.experimentalAcceptance,
                    onAccept: { [weak self] in self?.accept() }, onLearn: { [weak self] in self?.learn() },
                    onCopy: { [weak self] in self?.copyCandidate() }, onDismiss: { [weak self] in self?.dismiss() })
                self.registerCandidateKeys()
            } catch is CancellationError { }
            catch AccessibilityCaptureError.permissionRequired {
                if !automatic { self.statusLine?.title = "需要辅助功能权限；从 LM 菜单手动开启" }
            } catch {
                guard self.epoch == token else { return }
                self.statusLine?.title = error is CoachingProviderError || error is CredentialError
                    ? providerMessage(error) : "此输入框暂不支持候选读取或定位；原文未修改"
            }
        }
    }

    private func registerCandidateKeys() {
        let learn = GlobalHotKey(keyCode: UInt32(kVK_ANSI_K), identifier: 3) { [weak self] in self?.learn() }
        let dismiss = GlobalHotKey(keyCode: UInt32(kVK_ANSI_Period), identifier: 4) { [weak self] in self?.dismiss() }
        candidateKeys = [learn, dismiss]
        if preferences.experimentalAcceptance {
            candidateKeys.append(GlobalHotKey(keyCode: UInt32(kVK_Return), identifier: 2) { [weak self] in self?.accept() })
        }
        for key in candidateKeys {
            if !key.register() { statusLine?.title = "候选快捷键冲突；请用候选上的按钮" }
        }
    }

    private func dismiss() {
        suppressedSnapshot = proposal?.snapshot
        invalidate()
    }

    private func accept() {
        guard preferences.experimentalAcceptance, let proposal else { return }
        invalidate()
        Task { @MainActor in
            do {
                try await reader.replaceInline(range: proposal.placeholder.range, source: proposal.placeholder.text,
                    in: proposal.snapshot, with: proposal.replacement)
                statusLine?.title = "候选已接受；原生撤销仍待体验验证"
            } catch AccessibilityReplacementError.verificationFailed {
                statusLine?.title = "无法确认接受结果；请检查原文，必要时撤销"
            } catch {
                statusLine?.title = "未完成接受：焦点/输入变化或控件不支持；请重新请求"
            }
        }
    }

    private func copyCandidate() {
        guard let proposal else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(proposal.replacement, forType: .string)
        dismiss()
    }

    private func learn() {
        guard let proposal else { return }
        dismiss()
        learning.show(proposal, service: service)
    }
}
