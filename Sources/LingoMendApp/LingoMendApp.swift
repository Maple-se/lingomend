import AppKit
import ApplicationServices
import Carbon
import CoachCore
import MVPFlow
import PlatformBridge
import DiagnosticsCore

@main
enum LingoMendApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = LingoMendDelegate()
        app.delegate = delegate
        app.run()
    }
}

/// Explicit writing advice and read-only contextual interpretation share one cancellable session.
@MainActor
private final class LingoMendDelegate: NSObject, NSApplicationDelegate {
    private let reader = MacOSAccessibilityTextReader()
    private let readingReader = MacOSReadingSelectionReader()
    private let observer = MacOSFocusedTextObserver()
    private let diagnostics = AppDiagnostics()
    private lazy var service = SentenceService(preferences: AppPreferences.load(), diagnostics: diagnostics.recorder)
    private lazy var readingService = ReadingService(preferences: AppPreferences.load(), diagnostics: diagnostics.recorder)
    private let panel = SentenceCandidatePanel()
    private let readingPanel = ReadingPanel()
    private let notice = RequestNotice()
    private lazy var writer = NativeTextEditPaste(driver: MacOSTextEditPasteDriver(reader: reader), diagnostics: diagnostics.recorder)
    private let settingsWindow = SettingsWindow()
    private var preferences = AppPreferences.load()
    private var statusItem: NSStatusItem?
    private var statusLine: NSMenuItem?
    private var trigger: GlobalHotKey?
    private var readingKey: GlobalHotKey?
    private var dismissKey: GlobalHotKey?
    private var acceptKey: GlobalHotKey?
    private var escapeMonitor: Any?
    private var generation: Task<Void, Never>?
    private var epoch = UUID()
    private var hasPreview = false
    private var proposal: SentenceProposal?
    private var activeSnapshot: TextSnapshot?
    private var activeReading: ReadingCapture?
    private var acceptance: Task<Void, Never>?
    private var quitAfterAcceptance = false
    private var finishing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            await diagnostics.start()
            diagnostics.recorder.record(DiagnosticEvent(.appStarted))
            diagnostics.recorder.record(DiagnosticEvent(.permissionChecked,
                outcome: AXIsProcessTrusted() ? .success : .refused))
            diagnostics.recorder.record(DiagnosticEvent(.hotKeyRegistered,
                outcome: triggerRegistered ? .success : .failed, shortcut: .help))
            diagnostics.recorder.record(DiagnosticEvent(.hotKeyRegistered,
                outcome: readingRegistered ? .success : .failed, shortcut: .read))
        }
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "LM"
        let menu = NSMenu()
        let status = NSMenuItem(title: service.modeLabel, action: nil, keyEquivalent: "")
        status.isEnabled = false; statusLine = status; menu.addItem(status)
        let version = NSMenuItem(title: "LingoMend \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development") · T3 开发版", action: nil, keyEquivalent: "")
        version.isEnabled = false; menu.addItem(version)
        add("设置…", action: #selector(showSettings), to: menu)
        menu.addItem(.separator())
        let hint = NSMenuItem(title: "求助 ⌃⌥L · 接受 ⌃⌥↩ · 取消 Esc / ⌃⌥.", action: nil, keyEquivalent: "")
        hint.isEnabled = false; menu.addItem(hint)
        let readingHint = NSMenuItem(title: "选词 / 选句解释 ⌃⌥D", action: nil, keyEquivalent: "")
        readingHint.isEnabled = false; menu.addItem(readingHint)
        add("开启辅助功能权限…", action: #selector(requestAccessibility), to: menu)
        menu.addItem(.separator())
        add("退出 LingoMend", action: #selector(quitApp), to: menu)
        item.menu = menu; statusItem = item
        let hotKey = GlobalHotKey { [weak self] in self?.requestAdvice() }
        trigger = hotKey
        triggerRegistered = hotKey.register()
        if !triggerRegistered { status.title = "⌃⌥L 注册失败；请检查快捷键冲突" }
        let reading = GlobalHotKey(keyCode: UInt32(kVK_ANSI_D), identifier: 5) { [weak self] in self?.requestReading() }
        readingKey = reading; readingRegistered = reading.register()
        if !readingRegistered { status.title = "⌃⌥D 注册失败；请检查快捷键冲突" }
        observer.onChange = { [weak self] in self?.checkObservedChange() }
        observer.onUnavailable = { [weak self] in self?.discardChangedPreview() }
        reader.allowedApplications = ["com.apple.TextEdit"]
    }
    private var triggerRegistered = false
    private var readingRegistered = false

    private func add(_ title: String, action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self; menu.addItem(item)
    }
    @objc private func requestAccessibility() {
        let trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        diagnostics.recorder.record(DiagnosticEvent(.permissionChecked, outcome: trusted ? .success : .refused))
    }
    @objc private func quitApp() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        quitAfterAcceptance = true
        if acceptance != nil { feedback("正在完成粘贴检查和剪贴板清理，随后退出", persistent: true) }
        else { finishTermination() }
        return .terminateLater
    }
    private func finishTermination() {
        guard !finishing else { return }
        finishing = true; invalidate(reason: .userCancelled)
        diagnostics.recorder.record(DiagnosticEvent(.appStopping))
        // Flush only after acceptance's bounded clipboard cleanup, at most 300 ms more.
        diagnostics.recorder.finish {
            DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) }
        }
    }
    @objc private func showSettings() {
        guard acceptance == nil else { return }
        invalidate(reason: .settingsChanged)
        diagnostics.refresh()
        settingsWindow.show(preferences: preferences, diagnostics: diagnostics) { [weak self] updated in
            guard let self else { return }
            invalidate(reason: .settingsChanged); preferences = updated
            service = SentenceService(preferences: updated, diagnostics: diagnostics.recorder)
            readingService = ReadingService(preferences: updated, diagnostics: diagnostics.recorder)
            statusLine?.title = service.modeLabel
        }
    }

    private func feedback(_ text: String, persistent: Bool = false) {
        diagnostics.refresh()
        statusLine?.title = text
        notice.show(text, near: statusItem?.button, persistent: persistent)
    }

    private func checkObservedChange() {
        if let reading = activeReading {
            if !readingReader.isCurrent(reading) { discardChangedPreview() }
            return
        }
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
        invalidate(reason: .sourceOrFocusChanged)
        statusLine?.title = "文本或焦点已变化；可重新按快捷键求助"
    }

    private func invalidate(reason: DiagnosticReason? = nil) {
        if let reason, generation != nil || hasPreview {
            diagnostics.recorder.record(DiagnosticEvent(.candidateDismissed, outcome: .cancelled,
                reason: reason, stage: hasPreview ? .candidate : .model), operation: epoch)
        }
        epoch = UUID(); generation?.cancel(); generation = nil
        hasPreview = false; proposal = nil; activeSnapshot = nil; panel.hide(); notice.hide()
        activeReading = nil; readingReader.clear(); readingPanel.hide()
        unregisterInteractionKeys()
        observer.configure(enabled: false, allowedApplications: [])
    }

    private func unregisterInteractionKeys() {
        dismissKey?.unregister(); dismissKey = nil; acceptKey?.unregister(); acceptKey = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor); self.escapeMonitor = nil }
    }

    private func registerCancellation() {
        let token = epoch
        let key = GlobalHotKey(keyCode: UInt32(kVK_ANSI_Period), identifier: 4) { [weak self] in self?.invalidate(reason: .userCancelled) }
        dismissKey = key
        let registered = key.register()
        diagnostics.recorder.record(DiagnosticEvent(.hotKeyRegistered,
            outcome: registered ? .success : .failed, shortcut: .cancelPeriod), operation: token)
        if !registered { statusLine?.title = "取消快捷键冲突；可点击候选上的取消" }
        // Observe Escape's key code only, without consuming it or reading typed characters.
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == UInt16(kVK_Escape) else { return }
            MainActor.assumeIsolated {
                guard let self, self.epoch == token else { return }
                self.invalidate(reason: .userCancelled)
            }
        }
        diagnostics.recorder.record(DiagnosticEvent(.hotKeyRegistered,
            outcome: escapeMonitor != nil ? .success : .failed, shortcut: .cancelEscape), operation: token)
    }

    private func requestAdvice() {
        guard acceptance == nil else { return }
        invalidate(reason: .superseded)
        let operation = epoch
        diagnostics.recorder.record(DiagnosticEvent(.helpStarted), operation: operation)
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.TextEdit" else {
            diagnostics.recorder.record(DiagnosticEvent(.helpFailed, outcome: .refused, reason: .applicationNotAllowed), operation: operation)
            feedback("当前阶段请在 TextEdit 中使用 ⌃⌥L"); return
        }
        guard preferences.allowedApplications.contains("com.apple.TextEdit") else {
            diagnostics.recorder.record(DiagnosticEvent(.helpFailed, outcome: .refused, reason: .applicationNotAllowed), operation: operation)
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
            var stage: DiagnosticStage = .capture
            // Service owns model failures. The UI owns capture/scope/candidate failures only.
            func logFailure(_ error: Error) {
                guard stage != .model, !(error is CancellationError) else { return }
                diagnostics.recorder.record(DiagnosticEvent(.helpFailed, level: .warning,
                    outcome: .refused, reason: diagnosticReason(error), stage: stage), operation: token)
            }
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
                stage = .scope
                let scope = try SentenceScopeResolver().resolve(snapshot)
                diagnostics.recorder.record(DiagnosticEvent(.scopeResolved, stage: .scope,
                    scope: snapshot.selectedRange.length > 0 ? .selection : .currentSentence,
                    length: scope.target.text.utf16.count), operation: token)
                let request = try SentenceProposal.request(for: scope)
                statusLine?.title = "\(service.modeLabel) · \(request.intent.label)"
                stage = .model
                let advice = try await service.advice(request, operation: token)
                try Task.checkCancellation()
                guard epoch == token else { return }
                stage = .candidate
                guard try await reader.readFocusedText() == snapshot else { discardChangedPreview(); return }
                let proposal = try SentenceProposal(snapshot: snapshot, scope: scope, advice: advice)
                guard let anchor = try await reader.caretBounds(for: snapshot), epoch == token else {
                    diagnostics.recorder.record(DiagnosticEvent(.helpFailed, outcome: .refused,
                        reason: .anchorUnavailable, stage: .candidate), operation: token)
                    feedback("无法定位光标；请重新把光标放回表达中"); return
                }
                hasPreview = true
                self.proposal = proposal; notice.hide()
                diagnostics.recorder.record(DiagnosticEvent(.candidateShown,
                    outcome: diagnosticAdviceOutcome(advice), stage: .candidate), operation: token)
                panel.show(proposal, anchor: anchor, onAccept: { [weak self] in self?.accept() },
                    onDismiss: { [weak self] in self?.invalidate(reason: .userCancelled) })
                if proposal.advice.status == .suggest {
                    let accept = GlobalHotKey(keyCode: UInt32(kVK_Return), identifier: 2) { [weak self] in self?.accept() }
                    acceptKey = accept
                    let registered = accept.register()
                    diagnostics.recorder.record(DiagnosticEvent(.hotKeyRegistered,
                        outcome: registered ? .success : .failed, shortcut: .accept), operation: token)
                    if !registered { feedback("接受快捷键冲突；可点击候选上的接受") }
                }
            } catch is CancellationError { }
            catch AccessibilityCaptureError.permissionRequired {
                logFailure(AccessibilityCaptureError.permissionRequired)
                if epoch == token { feedback("需要辅助功能权限；从 LM 菜单手动开启") }
            } catch let error as SentenceScopeError {
                logFailure(error)
                guard epoch == token else { return }
                switch error {
                case .empty: feedback("当前表达为空；写一点内容后再求助")
                case .multipleSentences: feedback("当前支持一句；请将光标放进一句或缩小选区")
                case .tooLong: feedback("当前句超过 600 UTF-16 单位；请选择较短的独立句子")
                case .invalidRange: feedback("无法确认范围；请重新放置光标或选区")
                }
            } catch SentenceInputError.unsupported {
                logFailure(SentenceInputError.unsupported)
                if epoch == token { feedback("当前支持中英文文字表达；代码、公式和地址暂不处理") }
            } catch {
                logFailure(error)
                guard epoch == token else { return }
                feedback(error is CoachingProviderError || error is CredentialError
                    ? providerMessage(error) : "当前编辑器暂不支持读取或定位；请检查光标位置")
            }
        }
    }

    private func requestReading() {
        guard acceptance == nil else { return }
        invalidate(reason: .superseded)
        let token = epoch
        diagnostics.recorder.record(DiagnosticEvent(.readingStarted, shortcut: .read), operation: token)
        guard let identifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              preferences.globalAccessEnabled || preferences.allowedApplications.contains(identifier) else {
            diagnostics.recorder.record(DiagnosticEvent(.readingFailed, outcome: .refused,
                reason: .applicationNotAllowed, shortcut: .read), operation: token)
            feedback("请在设置中允许其他应用的按需读取，或先在已允许的 TextEdit 中体验"); return
        }
        observer.configure(enabled: true, allowedApplications: [identifier])
        registerCancellation(); feedback("正在读取选中词句…", persistent: true)
        generation = Task { @MainActor [weak self] in
            guard let self else { return }
            var stage: DiagnosticStage = .capture
            defer {
                if epoch == token {
                    generation = nil
                    if !hasPreview {
                        activeReading = nil; readingReader.clear(); unregisterInteractionKeys()
                        observer.configure(enabled: false, allowedApplications: [])
                    }
                }
            }
            do {
                let capture = try readingReader.capture()
                try Task.checkCancellation()
                guard epoch == token else { return }
                activeReading = capture
                observer.observeReadingSelection(from: readingReader)
                stage = .scope
                let request = try ReadingProposal.request(for: capture.scope)
                let scope: DiagnosticScope = switch request.contextKind {
                case .sentence: .currentSentence
                case .excerpt: .excerpt
                case .selectionOnly: .selectionOnly
                }
                diagnostics.recorder.record(DiagnosticEvent(.readingCaptured, stage: .scope,
                    scope: scope, shortcut: .read, length: request.context.utf16.count), operation: token)
                stage = .model
                feedback("\(service.modeLabel) · 正在解释选中内容…", persistent: true)
                let explanation = try await readingService.explain(request, operation: token)
                try Task.checkCancellation()
                guard epoch == token else { return }
                stage = .candidate
                guard readingReader.isCurrent(capture) else { discardChangedPreview(); return }
                hasPreview = true; notice.hide()
                readingPanel.show(request: request, explanation: explanation, anchor: capture.anchor,
                    onDismiss: { [weak self] in self?.invalidate(reason: .userCancelled) })
                diagnostics.recorder.record(DiagnosticEvent(.readingShown, outcome: .success,
                    stage: .candidate, scope: scope, shortcut: .read), operation: token)
                statusLine?.title = "语境解释已显示 · 不修改原文"
            } catch is CancellationError { }
            catch {
                guard epoch == token else { return }
                if stage != .model {
                    diagnostics.recorder.record(DiagnosticEvent(.readingFailed, outcome: .refused,
                        reason: diagnosticReason(error), stage: stage, shortcut: .read), operation: token)
                }
                if case AccessibilityCaptureError.permissionRequired = error {
                    feedback("需要辅助功能权限；从 LM 菜单手动开启")
                } else if case ReadingScopeError.tooLong = error {
                    feedback("选区过长；请选择一个词、句子或不超过 1200 UTF-16 单位的短段落")
                } else if error is CoachingProviderError || error is CredentialError {
                    if !preferences.networkEnabled, case CoachingProviderError.refused = error {
                        feedback("本地演示只解释样例 current；可在设置中开启模型服务解释其他内容")
                    } else { feedback(providerMessage(error)) }
                } else {
                    feedback("未取得可访问的文字选区；请先选中词句。扫描 PDF 暂不支持")
                }
            }
        }
    }

    private func accept() {
        guard acceptance == nil, let proposal, proposal.advice.status == .suggest else { return }
        let plan: SentenceEditPlan
        let operation = epoch
        do { plan = try SentenceEditPlan(original: proposal.snapshot, scope: proposal.scope, replacement: proposal.advice.replacement) }
        catch {
            diagnostics.recorder.record(DiagnosticEvent(.acceptanceFailed, outcome: .refused,
                reason: .invalidRange, stage: .preflight, dispatched: false), operation: operation)
            invalidate(); feedback("无法确认编辑范围；请重新求助"); return
        }
        // Remove preview and its keys before starting; repeated clicks cannot reuse it.
        invalidate()
        feedback("正在接受建议…", persistent: true)
        acceptance = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                acceptance = nil
                if quitAfterAcceptance { finishTermination() }
            }
            do {
                let result = try await writer.accept(plan, operation: operation)
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
