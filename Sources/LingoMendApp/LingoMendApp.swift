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
    private lazy var writer = NativeTextPaste(driver: MacOSNativePasteDriver(reader: reader), diagnostics: diagnostics.recorder)
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
    private var activeApplication: NSRunningApplication?
    private var acceptance: Task<Void, Never>?
    private var quitAfterAcceptance = false
    private var finishing = false

    private func record(_ event: DiagnosticEvent, operation: UUID? = nil,
                        application: NSRunningApplication? = nil) {
        let app = application ?? activeApplication ?? NSWorkspace.shared.frontmostApplication
        diagnostics.recorder.record(event.withApplication(
            identifier: app?.bundleIdentifier,
            name: app?.localizedName ?? app?.bundleIdentifier), operation: operation)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            await diagnostics.start()
            record(DiagnosticEvent(.appStarted))
            record(DiagnosticEvent(.permissionChecked,
                outcome: AXIsProcessTrusted() ? .success : .refused))
            record(DiagnosticEvent(.hotKeyRegistered,
                outcome: triggerRegistered ? .success : .failed, shortcut: .help))
            record(DiagnosticEvent(.hotKeyRegistered,
                outcome: readingRegistered ? .success : .failed, shortcut: .read))
        }
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "LM"
        let menu = NSMenu()
        let status = NSMenuItem(title: service.modeLabel, action: nil, keyEquivalent: "")
        status.isEnabled = false; statusLine = status; menu.addItem(status)
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let version = NSMenuItem(title: "LingoMend \(shortVersion) (build \(build)) · T3 开发版", action: nil, keyEquivalent: "")
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
        reader.allowedApplications = []
    }
    private var triggerRegistered = false
    private var readingRegistered = false

    private func add(_ title: String, action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self; menu.addItem(item)
    }
    @objc private func requestAccessibility() {
        let trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        record(DiagnosticEvent(.permissionChecked, outcome: trusted ? .success : .refused))
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
        record(DiagnosticEvent(.appStopping))
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
            record(DiagnosticEvent(.candidateDismissed, outcome: .cancelled,
                reason: reason, stage: hasPreview ? .candidate : .model), operation: epoch)
        }
        epoch = UUID(); generation?.cancel(); generation = nil
        hasPreview = false; proposal = nil; activeSnapshot = nil; panel.hide(); notice.hide()
        activeReading = nil; readingReader.clear(); readingPanel.hide()
        unregisterInteractionKeys()
        observer.configure(enabled: false, allowedApplications: [])
        activeApplication = nil
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
        record(DiagnosticEvent(.hotKeyRegistered,
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
        record(DiagnosticEvent(.hotKeyRegistered,
            outcome: escapeMonitor != nil ? .success : .failed, shortcut: .cancelEscape), operation: token)
    }

    private func requestAdvice() {
        guard acceptance == nil else { return }
        invalidate(reason: .superseded)
        let operation = epoch
        let application = NSWorkspace.shared.frontmostApplication
        record(DiagnosticEvent(.helpStarted), operation: operation, application: application)
        guard let identifier = application?.bundleIdentifier,
              preferences.globalAccessEnabled || preferences.allowedApplications.contains(identifier) else {
            record(DiagnosticEvent(.helpFailed, outcome: .refused, reason: .applicationNotAllowed),
                operation: operation, application: application)
            feedback("请在设置中允许其他应用的按需求助，或勾选 TextEdit"); return
        }
        activeApplication = application
        reader.allowedApplications = [identifier]
        // Subscribe only while a requested operation is active, solely to invalidate it.
        // Initial callbacks occur before the task starts and never schedule model work.
        observer.configure(enabled: true, allowedApplications: [identifier])
        let token = epoch
        feedback("正在识别当前表达…", persistent: true)
        registerCancellation()
        generation = Task { @MainActor [weak self] in
            guard let self else { return }
            var stage: DiagnosticStage = .capture
            // Service owns model failures. The UI owns capture/scope/candidate failures only.
            @MainActor func logFailure(_ error: Error) {
                guard stage != .model, !(error is CancellationError) else { return }
                record(DiagnosticEvent(.helpFailed, level: .warning,
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
                guard reader.capabilities?.canAccept(selection: snapshot.selectedRange) == true else {
                    record(DiagnosticEvent(.helpFailed, outcome: .refused,
                        reason: .unsupportedInput, stage: .capture), operation: token)
                    feedback("此区域未提供可编辑范围；阅读请选中文字后按 ⌃⌥D"); return
                }
                stage = .scope
                let scope = try WritingScopeResolver().resolve(snapshot)
                record(DiagnosticEvent(.scopeResolved, stage: .scope,
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
                    record(DiagnosticEvent(.helpFailed, outcome: .refused,
                        reason: .anchorUnavailable, stage: .candidate), operation: token)
                    feedback("无法定位光标；请重新把光标放回表达中"); return
                }
                hasPreview = true
                self.proposal = proposal; notice.hide()
                record(DiagnosticEvent(.candidateShown,
                    outcome: diagnosticAdviceOutcome(advice), stage: .candidate), operation: token)
                panel.show(proposal, anchor: anchor, onAccept: { [weak self] in self?.accept() },
                    onDismiss: { [weak self] in self?.invalidate(reason: .userCancelled) })
                if proposal.advice.status == .suggest {
                    let accept = GlobalHotKey(keyCode: UInt32(kVK_Return), identifier: 2) { [weak self] in self?.accept() }
                    acceptKey = accept
                    let registered = accept.register()
                    record(DiagnosticEvent(.hotKeyRegistered,
                        outcome: registered ? .success : .failed, shortcut: .accept), operation: token)
                    if !registered { feedback("接受快捷键冲突；可点击候选上的接受") }
                }
            } catch is CancellationError { }
            catch AccessibilityCaptureError.disjointSelection {
                logFailure(AccessibilityCaptureError.disjointSelection)
                if epoch == token { feedback("当前有多个选区或光标；请只保留一个连续选区或光标后再求助") }
            }
            catch AccessibilityCaptureError.permissionRequired {
                logFailure(AccessibilityCaptureError.permissionRequired)
                if epoch == token { feedback("需要辅助功能权限；从 LM 菜单手动开启") }
            } catch let error as AccessibilityCaptureError {
                logFailure(error)
                guard epoch == token else { return }
                switch error {
                case .focusedElementUnavailable:
                    feedback("当前应用没有提供可定位的编辑器；请把光标放回输入框后重试")
                case .focusedWindowUnavailable:
                    feedback("当前应用没有提供可访问的前台窗口；请重新聚焦输入框后重试")
                case .editableControlUnavailable:
                    feedback("前台窗口未暴露可编辑文字控件；请先点击输入框后重试")
                case .applicationUnavailable:
                    feedback("无法识别当前前台应用；请重新聚焦输入框后重试")
                case .textUnavailable:
                    feedback("当前应用未暴露可读取的文字；请先选中短语，或换普通文本输入框")
                case .selectionUnavailable:
                    feedback("当前应用未暴露光标或选区位置；请先选中短语后重试")
                case .invalidSelection:
                    feedback("当前选区范围无效；请重新选择连续文字")
                case .focusChangedDuringCapture:
                    feedback("读取期间焦点发生变化；请保持输入框在前台后重试")
                case .protectedField:
                    feedback("安全输入框不会被读取")
                case .textTooLarge:
                    feedback("当前输入框内容过长；请缩小到当前句或短段落")
                case .disjointSelection:
                    feedback("当前有多个选区或光标；请只保留一个连续选区或光标后再求助")
                case .applicationNotAllowed:
                    feedback("请在设置中允许当前应用的按需求助")
                case .permissionRequired:
                    feedback("需要辅助功能权限；从 LM 菜单手动开启")
                }
            } catch let error as SentenceScopeError {
                logFailure(error)
                guard epoch == token else { return }
                switch error {
                case .empty: feedback("当前表达为空；写一点内容后再求助")
                case .multipleSentences: feedback("请明确选中需要帮助的短段落，或把光标放进一句")
                case .tooLong: feedback("当前句超过 600 或选段超过 1200 UTF-16 单位；请缩小选区")
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
        let application = NSWorkspace.shared.frontmostApplication
        record(DiagnosticEvent(.readingStarted, shortcut: .read), operation: token, application: application)
        guard let identifier = application?.bundleIdentifier,
              preferences.globalAccessEnabled || preferences.allowedApplications.contains(identifier) else {
            record(DiagnosticEvent(.readingFailed, outcome: .refused,
                reason: .applicationNotAllowed, shortcut: .read), operation: token, application: application)
            feedback("请在设置中允许其他应用的按需读取，或先在已允许的 TextEdit 中体验"); return
        }
        activeApplication = application
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
                record(DiagnosticEvent(.readingCaptured, stage: .scope,
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
                record(DiagnosticEvent(.readingShown, outcome: .success,
                    stage: .candidate, scope: scope, shortcut: .read), operation: token)
                statusLine?.title = "语境解释已显示 · 不修改原文"
            } catch is CancellationError { }
            catch {
                guard epoch == token else { return }
                if stage != .model {
                    record(DiagnosticEvent(.readingFailed, outcome: .refused,
                        reason: diagnosticReason(error), stage: stage, shortcut: .read), operation: token)
                }
                if case AccessibilityCaptureError.permissionRequired = error {
                    feedback("需要辅助功能权限；从 LM 菜单手动开启")
                } else if case AccessibilityCaptureError.disjointSelection = error {
                    feedback("请选择一个连续的词句范围，再按 ⌃⌥D")
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
        do { plan = try SentenceEditPlan(original: proposal.snapshot, scope: proposal.scope,
            replacement: proposal.advice.replacement, preserveExplicitSelection: reader.capabilities?.selectableRange == false) }
        catch {
            record(DiagnosticEvent(.acceptanceFailed, outcome: .refused,
                reason: .invalidRange, stage: .preflight, dispatched: false), operation: operation)
            invalidate(); feedback("无法确认编辑范围；请重新求助"); return
        }
        let targetApplication = activeApplication
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
                let result = try await writer.accept(plan, operation: operation,
                    applicationIdentifier: targetApplication?.bundleIdentifier,
                    applicationName: targetApplication?.localizedName)
                if result.clipboard == .failed { feedback("文本已更新，但剪贴板恢复失败；请检查剪贴板") }
                else if !result.caretPositioned { feedback("文本已更新；光标位置未确认，请检查后继续写作") }
                else if !result.preservesFormatting {
                    feedback("已接受 · 以普通文本写入，格式未保证；在原编辑器按 ⌘Z 可撤销")
                }
                else { feedback("已接受 · 在原编辑器按 ⌘Z 可撤销") }
            } catch NativePasteError.resultUnconfirmed {
                feedback("粘贴结果未确认；请检查原文，必要时在原编辑器按 ⌘Z。不会自动重试")
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
