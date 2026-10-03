import AppKit
import CoachCore
import MVPFlow
import PlatformBridge

/// Native editor: no Accessibility; networking is opt-in via shared settings.
@MainActor
final class DemoInputWindow: NSObject, NSTextViewDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var editor: NSTextView?
    private var task: Task<Void, Never>?
    private var proposal: InlineProposal?
    private let candidatePanel = InlineCandidatePanel()
    private let learning = LearningPresenter()
    private var service = ExpressionService(preferences: AppPreferences())
    private let status = NSTextField(labelWithString: "本地固定样例 · 不联网 · 无需辅助功能权限")
    private var epoch = UUID()

    func configure(service: ExpressionService) {
        suspend(); self.service = service
        status.stringValue = "\(service.modeLabel) · 无需辅助功能权限"
        if window?.isKeyWindow == true { schedule() }
    }

    func suspend() { invalidate(); learning.cancel() }

    func show(service: ExpressionService) {
        configure(service: service)
        if let window {
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            schedule(); return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 370),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "LingoMend · 输入体验"
        window.isReleasedWhenClosed = false; window.delegate = self
        let content = NSView(frame: window.contentLayoutRect)
        let heading = NSTextField(labelWithString: "Write what you can. Learn what you can't.")
        heading.font = .systemFont(ofSize: 20, weight: .semibold)
        let hint = NSTextField(wrappingLabelWithString: "用你原来的输入法写英文，不会的地方留下中文。试试：This works 轻载条件下.\n停顿后出现候选；接受 ⌃⌥↩ · 学习 ⌃⌥K · 收起 ⌃⌥.")
        hint.textColor = .secondaryLabelColor
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 620, height: 180))
        editor.isRichText = false; editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.font = .systemFont(ofSize: 17)
        editor.textContainerInset = NSSize(width: 12, height: 12)
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.delegate = self
        editor.string = "This works 轻载条件下."
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        scroll.documentView = editor
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        for view in [heading, hint, scroll, status] {
            view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            hint.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            hint.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: hint.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 16),
            scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -16),
            status.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        ])
        window.contentView = content
        self.window = window; self.editor = editor
        window.center(); window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor); NSApp.activate(ignoringOtherApps: true)
        schedule()
    }

    func textDidChange(_ notification: Notification) { schedule() }
    func textViewDidChangeSelection(_ notification: Notification) { schedule() }
    func windowDidResignKey(_ notification: Notification) { invalidate() }
    func windowDidBecomeKey(_ notification: Notification) { schedule() }
    func windowWillClose(_ notification: Notification) { suspend() }

    func accept() {
        guard let proposal, let editor, window?.isKeyWindow == true,
              !editor.hasMarkedText(), snapshot() == proposal.snapshot else { invalidate(); return }
        let range = proposal.placeholder.range
        let originalCaret = editor.selectedRange().location
        editor.insertText(proposal.replacement, replacementRange: range)
        let newCaret = originalCaret >= NSMaxRange(range)
            ? originalCaret + proposal.replacement.utf16.count - range.length
            : range.location + proposal.replacement.utf16.count
        editor.setSelectedRange(NSRange(location: newCaret, length: 0))
        window?.makeFirstResponder(editor)
        status.stringValue = "已接受 · 继续写作；⌘Z 使用此编辑器原生撤销"
        invalidate()
    }

    func learn() {
        guard let proposal else { return }
        invalidate()
        learning.show(proposal, service: service)
    }
    func dismiss() { invalidate() }
    var hasCandidate: Bool { proposal != nil && window?.isKeyWindow == true }

    private func invalidate() {
        epoch = UUID(); task?.cancel(); task = nil; proposal = nil; candidatePanel.hide()
    }
    private func snapshot() -> TextSnapshot? {
        guard let editor else { return nil }
        return TextSnapshot(applicationIdentifier: "com.maplese.lingomend.demo",
            focusedElementIdentifier: "local-editor", text: editor.string,
            selectedRange: editor.selectedRange(), revisionToken: editor.string)
    }
    private func schedule() {
        invalidate()
        let token = epoch
        task = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(1_000)) } catch { return }
            guard let self, self.epoch == token, let editor = self.editor,
                  self.window?.isKeyWindow == true, !editor.hasMarkedText(),
                  let snapshot = self.snapshot(),
                  let placeholder = InlinePlaceholderResolver().resolve(snapshot) else { return }
            do {
                guard let request = InlineProposal.request(for: placeholder, context: self.service.preferences.context,
                    correctionLevel: self.service.preferences.correctionLevel) else { return }
                let service = self.service
                self.status.stringValue = "\(service.modeLabel) · 生成候选…"
                guard let replacement = try await service.candidate(request) else {
                    if self.epoch == token { self.status.stringValue = "\(service.modeLabel) · 暂无候选，请继续写作" }
                    return
                }
                try Task.checkCancellation()
                guard self.epoch == token, self.snapshot() == snapshot,
                      !editor.hasMarkedText(), self.window?.isKeyWindow == true,
                      let proposal = InlineProposal(snapshot: snapshot, placeholder: placeholder, replacement: replacement) else { return }
                let bounds = editor.firstRect(forCharacterRange: snapshot.selectedRange, actualRange: nil)
                guard bounds.height > 0 else { return }
                self.proposal = proposal
                self.status.stringValue = "\(service.modeLabel) · 候选仅填补中文占位；请判断含义后接受"
                let desktopTop = NSScreen.screens.first?.frame.maxY ?? 0
                let anchor = CGRect(x: bounds.minX, y: desktopTop - bounds.maxY, width: bounds.width, height: bounds.height)
                self.candidatePanel.show(text: proposal.replacement, anchor: anchor, canAccept: true,
                    onAccept: { [weak self] in self?.accept() },
                    onLearn: { [weak self] in self?.learn() }, onCopy: {},
                    onDismiss: { [weak self] in self?.dismiss() })
            } catch is CancellationError { }
            catch { if self.epoch == token { self.status.stringValue = providerMessage(error) } }
        }
    }
}
