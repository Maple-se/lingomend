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
private final class LingoMendDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let reader = MacOSAccessibilityTextReader()
    private let readingReader = MacOSReadingSelectionReader()
    private let observer = MacOSFocusedTextObserver()
    private let diagnostics = AppDiagnostics()
    private lazy var service = SentenceService(preferences: AppPreferences.load(), diagnostics: diagnostics.recorder)
    private lazy var readingService = ReadingService(preferences: AppPreferences.load(), diagnostics: diagnostics.recorder)
    private let panel = SentenceCandidatePanel()
    private let recentPanel = RecentSuggestionPanel()
    private let readingPanel = ReadingPanel()
    private let notice = RequestNotice()
    private lazy var writer = NativeTextPaste(driver: MacOSNativePasteDriver(reader: reader), diagnostics: diagnostics.recorder)
    private let settingsWindow = SettingsWindow()
    private var preferences = AppPreferences.load()
    private var statusItem: NSStatusItem?
    private var statusLine: NSMenuItem?
    private var modeLine: NSMenuItem?
    private var helpKeyLine: NSMenuItem?
    private var readKeyLine: NSMenuItem?
    private var permissionLine: NSMenuItem?
    private var recentMenuItem: NSMenuItem?
    private var trigger: GlobalHotKey?
    private var readingKey: GlobalHotKey?
    private var dismissKey: GlobalHotKey?
    private var acceptKey: GlobalHotKey?
    private var escapeMonitor: Any?
    private var generation: Task<Void, Never>?
    private var epoch = UUID()
    private var hasPreview = false
    private var proposal: SentenceProposal?
    private var activeExplanation: WritingExplanation?
    private var recentSuggestions = RecentSuggestionStore()
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
        let symbol = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "LingoMend，写作助手")
        symbol?.isTemplate = true
        item.button?.image = symbol
        item.button?.title = symbol == nil ? "LM" : ""
        item.button?.toolTip = "LingoMend · 按需写作与阅读"
        item.button?.setAccessibilityLabel("LingoMend，写作助手")
        let menu = NSMenu()
        menu.delegate = self
        let heading = NSMenuItem(title: "LingoMend", action: nil, keyEquivalent: "")
        heading.isEnabled = false; menu.addItem(heading)
        let mode = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        mode.isEnabled = false; modeLine = mode; menu.addItem(mode)
        let status = NSMenuItem(title: "就绪 · 先在编辑器写作，再按快捷键求助", action: nil, keyEquivalent: "")
        status.isEnabled = false; statusLine = status; menu.addItem(status)
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let version = NSMenuItem(title: "LingoMend \(shortVersion) (build \(build))", action: nil, keyEquivalent: "")
        version.isEnabled = false; menu.addItem(version)
        menu.addItem(.separator())
        let help = NSMenuItem(title: "⌃⌥L  写作帮助", action: nil, keyEquivalent: "")
        help.isEnabled = false; helpKeyLine = help; menu.addItem(help)
        let read = NSMenuItem(title: "⌃⌥D  阅读选区", action: nil, keyEquivalent: "")
        read.isEnabled = false; readKeyLine = read; menu.addItem(read)
        let acceptHint = NSMenuItem(title: "候选中：⌃⌥↩ 接受 · Esc / ⌃⌥. 收起", action: nil, keyEquivalent: "")
        acceptHint.isEnabled = false; menu.addItem(acceptHint)
        let recent = NSMenuItem(title: "最近一次建议…", action: #selector(showRecentSuggestion), keyEquivalent: "")
        recent.target = self; recent.isEnabled = false; recentMenuItem = recent; menu.addItem(recent)
        menu.addItem(.separator())
        add("设置…", action: #selector(showSettings), to: menu)
        let permission = NSMenuItem(title: "", action: #selector(requestAccessibility), keyEquivalent: "")
        permission.target = self; permissionLine = permission; menu.addItem(permission)
        menu.addItem(.separator())
        add("退出 LingoMend", action: #selector(quitApp), to: menu)
        item.menu = menu; statusItem = item
        let hotKey = GlobalHotKey { [weak self] in self?.requestAdvice() }
        trigger = hotKey
        triggerRegistered = hotKey.register()
        let reading = GlobalHotKey(keyCode: UInt32(kVK_ANSI_D), identifier: 5) { [weak self] in self?.requestReading() }
        readingKey = reading; readingRegistered = reading.register()
        refreshMenu()
        observer.onChange = { [weak self] in self?.checkObservedChange() }
        observer.onUnavailable = { [weak self] in self?.discardChangedPreview(reason: .focusChanged) }
        reader.allowedApplications = []
    }
    private var triggerRegistered = false
    private var readingRegistered = false

    func menuWillOpen(_ menu: NSMenu) { refreshMenu() }

    private func refreshMenu() {
        modeLine?.title = preferences.networkEnabled ? "状态：模型服务已开启" : "状态：本地固定样例"
        helpKeyLine?.title = triggerRegistered ? "⌃⌥L  写作帮助" : "⌃⌥L  注册失败，请检查快捷键冲突"
        readKeyLine?.title = readingRegistered ? "⌃⌥D  阅读选区" : "⌃⌥D  注册失败，请检查快捷键冲突"
        recentMenuItem?.title = recentSuggestions.latest == nil ? "最近一次建议（暂无）" : "最近一次建议…"
        recentMenuItem?.isEnabled = recentSuggestions.latest != nil
        let trusted = AXIsProcessTrusted()
        permissionLine?.title = trusted ? "辅助功能权限：已授权" : "辅助功能权限：需要授权…"
        permissionLine?.isEnabled = !trusted
    }

    private func add(_ title: String, action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self; menu.addItem(item)
    }
    @objc private func requestAccessibility() {
        let trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        record(DiagnosticEvent(.permissionChecked, outcome: trusted ? .success : .refused))
        refreshMenu()
    }
    @objc private func quitApp() { NSApp.terminate(nil) }
    @objc private func showRecentSuggestion() {
        guard let latest = recentSuggestions.latest else {
            feedback("本次会话还没有已接受的建议")
            return
        }
        recentPanel.show(latest, onDismiss: { [weak self] in self?.recentPanel.hide() })
    }
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
            refreshMenu()
        }
    }

    private func feedback(_ text: String, persistent: Bool = false,
                          actionTitle: String? = nil, action: (@MainActor () -> Void)? = nil) {
        diagnostics.refresh()
        statusLine?.title = text
        notice.show(text, near: statusItem?.button, persistent: persistent,
                    actionTitle: actionTitle, action: action)
    }

    private func checkObservedChange() {
        if let reading = activeReading {
            if let reason = readingReader.changeReason(for: reading) { discardChangedPreview(reason: reason) }
            return
        }
        guard let snapshot = activeSnapshot, acceptance == nil else { return }
        let token = epoch
        Task { @MainActor [weak self] in
            guard let self, epoch == token else { return }
            // AX notifications may repeat without any real source/selection change.
            do {
                let current = try await reader.readFocusedText()
                guard epoch == token, let reason = current.changeReason(comparedTo: snapshot) else { return }
                discardChangedPreview(reason: reason)
            } catch {
                guard epoch == token else { return }
                discardChangedPreview(reason: .sourceReadFailed)
            }
        }
    }

    private func discardChangedPreview(reason: DiagnosticReason = .sourceOrFocusChanged) {
        guard acceptance == nil, generation != nil || hasPreview else { return }
        invalidate(reason: reason)
        statusLine?.title = reason == .sourceReadFailed
            ? "暂时无法重读原输入区域；可重新按快捷键求助"
            : "文本、选区或焦点已变化；可重新按快捷键求助"
    }

    private func invalidate(reason: DiagnosticReason? = nil) {
        if let reason, generation != nil || hasPreview {
            record(DiagnosticEvent(.candidateDismissed, outcome: .cancelled,
                reason: reason, stage: hasPreview ? .candidate : .model), operation: epoch)
        }
        epoch = UUID(); generation?.cancel(); generation = nil
        hasPreview = false; proposal = nil; activeExplanation = nil; activeSnapshot = nil
        panel.hide(); notice.hide()
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
            feedback("请在设置中允许当前应用，或勾选 TextEdit", actionTitle: "打开设置",
                     action: { [weak self] in self?.showSettings() }); return
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
                let snapshot = try await reader.readFocusedText(diagnostics: diagnostics.recorder, operation: token)
                try Task.checkCancellation()
                guard epoch == token else { return }
                activeSnapshot = snapshot
                observer.observeWritingSelection(from: reader)
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
                let current = try await reader.readFocusedText()
                if let reason = current.changeReason(comparedTo: snapshot) { discardChangedPreview(reason: reason); return }
                let proposal = try SentenceProposal(snapshot: snapshot, scope: scope, advice: advice)
                guard let anchor = try await reader.caretBounds(for: snapshot), epoch == token else {
                    record(DiagnosticEvent(.helpFailed, outcome: .refused,
                        reason: .anchorUnavailable, stage: .candidate), operation: token)
                    feedback("无法定位光标；请重新把光标放回表达中"); return
                }
                hasPreview = true
                self.proposal = proposal; activeExplanation = nil; notice.hide()
                record(DiagnosticEvent(.candidateShown,
                    outcome: diagnosticAdviceOutcome(advice), stage: .candidate), operation: token)
                panel.show(proposal, anchor: anchor, onAccept: { [weak self] in self?.accept() },
                    onDismiss: { [weak self] in self?.invalidate(reason: .userCancelled) },
                    onExplain: { [weak self] in
                        guard let self else { throw CancellationError() }
                        return try await self.explain(proposal: proposal, operation: token)
                    })
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
                if epoch == token { feedback("需要辅助功能权限；请在系统设置中授权 LingoMend",
                    actionTitle: "打开设置", action: { [weak self] in self?.showSettings() }) }
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
                    feedback("需要辅助功能权限；请在系统设置中授权 LingoMend",
                        actionTitle: "打开设置", action: { [weak self] in self?.showSettings() })
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

    private func explain(proposal: SentenceProposal, operation: UUID) async throws -> WritingExplanation? {
        guard epoch == operation, self.proposal?.request == proposal.request,
              proposal.advice.status == .suggest else { throw CancellationError() }
        let request = try WritingExplanationRequest(request: proposal.request,
            replacement: proposal.advice.replacement)
        statusLine?.title = "正在解释这次修改…"
        do {
            let result = try await service.explain(request, operation: operation)
            guard epoch == operation, self.proposal?.request == proposal.request else {
                throw CancellationError()
            }
            activeExplanation = result
            statusLine?.title = result == nil ? "暂时没有可用解释 · 仍可接受" : "修改解释已显示 · 仍可接受"
            return result
        } catch {
            if epoch == operation { statusLine?.title = "解释暂时失败 · 仍可接受" }
            throw error
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
            feedback("请在设置中允许当前应用，或先在已允许的 TextEdit 中体验",
                actionTitle: "打开设置", action: { [weak self] in self?.showSettings() }); return
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
                let capture = try readingReader.capture(diagnostics: diagnostics.recorder, operation: token)
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
                if let reason = readingReader.changeReason(for: capture) { discardChangedPreview(reason: reason); return }
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
                    feedback("需要辅助功能权限；请在系统设置中授权 LingoMend",
                        actionTitle: "打开设置", action: { [weak self] in self?.showSettings() })
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
        let recentSuggestion = RecentAcceptedSuggestion(proposal: proposal, explanation: activeExplanation)
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
                recentSuggestions.remember(recentSuggestion)
                recentMenuItem?.isEnabled = true
                recentMenuItem?.title = "最近一次建议…"
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
