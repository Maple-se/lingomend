import AppKit
import Combine
import CoachCore
import MVPFlow
import SwiftUI

private final class NonActivatingSentencePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class WritingExplanationController: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case loaded(WritingExplanation)
        case unavailable
        case failed
    }

    @Published private(set) var state: State = .idle
    private let action: @MainActor () async throws -> WritingExplanation?
    private var task: Task<Void, Never>?

    init(action: @escaping @MainActor () async throws -> WritingExplanation?) {
        self.action = action
    }

    var explanation: WritingExplanation? {
        guard case .loaded(let explanation) = state else { return nil }
        return explanation
    }

    func start() {
        guard state != .loading else { return }
        task?.cancel()
        state = .loading
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await action()
                if let result { state = .loaded(result) } else { state = .unavailable }
            } catch is CancellationError {
                if state == .loading { state = .idle }
            } catch {
                state = .failed
            }
            task = nil
        }
    }

    func cancel() {
        task?.cancel(); task = nil
        if state == .loading { state = .idle }
    }
}

@MainActor
final class SentenceCandidatePanel {
    private var panel: NSPanel?
    private let session = WritingCardSession()
    private var placement: WritingCardPlacement?
    private var hideTask: Task<Void, Never>?

    var explanation: WritingExplanation? { session.explanation?.explanation }

    func hide() {
        hideTask?.cancel(); hideTask = nil
        session.hide(); panel?.orderOut(nil)
        placement = nil
    }

    func start(anchor: CGRect, onDismiss: @escaping @MainActor () -> Void) {
        hide()
        let expanded = PanelPlacement.frame(anchor: anchor,
            preferredSize: NSSize(width: 470, height: 400))
        placement = WritingCardPlacement(expanded: expanded, anchor: anchor,
            primaryTop: NSScreen.screens.first?.frame.maxY ?? 0)
        let frame = placement!.frame(compact: true)
        let panel = self.panel ?? NonActivatingSentencePanel(contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating; panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
        panel.hasShadow = true; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        // A single hosting view and panel survive all phases of the request.
        if self.panel == nil {
            let content = NSHostingView(rootView: WritingCardView(session: session,
                onDismiss: { [weak self] in self?.dismiss() }))
            // The panel owns its frame. Outgoing SwiftUI transition content
            // must not feed its temporary minimum size back into NSWindow.
            content.sizingOptions = []
            panel.contentView = content
        }
        session.start(onDismiss: onDismiss)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel
        announce("正在识别当前表达。可按 Escape 取消。")
    }

    func show(_ proposal: SentenceProposal, onAccept: @escaping @MainActor () -> Void,
              onExplain: @escaping @MainActor () async throws -> WritingExplanation?) {
        guard placement != nil, session.phase == .loading else { return }
        session.show(proposal, onAccept: onAccept, onExplain: onExplain)
        resize(compact: false)
        announce(proposal.advice.status == .suggest
            ? "写作建议已显示。请核对原文和建议，按 Control Option Return 接受。"
            : "写作反馈已显示。")
    }

    @discardableResult
    func beginAcceptance() -> Bool {
        guard session.beginAcceptance() else { return false }
        resize(compact: true)
        return true
    }

    func completeAcceptance(message: String) {
        guard session.phase == .accepting else { return }
        session.completeAcceptance(message: message)
        announce(message)
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(3))
                self?.hide()
            } catch { }
        }
    }

    private func dismiss() {
        guard session.phase != .accepting else { return }
        session.dismiss()
        hide()
    }

    private func resize(compact: Bool) {
        guard let panel, let placement else { return }
        let frame = placement.frame(compact: compact)
        let duration = WritingCardMotion.duration(
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        if duration == 0 {
            panel.setFrame(frame, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                panel.animator().setFrame(frame, display: true)
            }
        }
    }

    private func announce(_ message: String) {
        guard let panel else { return }
        NSAccessibility.post(element: panel, notification: .announcementRequested,
            userInfo: [.announcement: message])
    }
}

private struct WritingCardView: View {
    @ObservedObject var session: WritingCardSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            if session.phase == .candidate, let proposal = session.proposal,
               let explanation = session.explanation {
                SentenceCandidateView(proposal: proposal, explanationController: explanation,
                    onAccept: session.accept, onDismiss: onDismiss)
                    .transition(.opacity)
            } else if session.phase != .hidden {
                HStack(spacing: 12) {
                    if session.phase == .accepted {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if reduceMotion {
                        Image(systemName: "hourglass").foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(session.message).font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        if session.phase == .loading {
                            Text("Esc 取消 · 不会自动修改原文")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 4)
                    if session.phase != .accepting {
                        Button(action: onDismiss) { Image(systemName: "xmark") }
                            .buttonStyle(.plain).frame(width: 32, height: 32)
                            .accessibilityLabel("收起写作卡片")
                    }
                }.padding(16).transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .modifier(CandidateCardSurface())
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: session.phase)
    }
}

private struct SentenceCandidateView: View {
    let proposal: SentenceProposal
    @ObservedObject var explanationController: WritingExplanationController
    let onAccept: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label(proposal.label, systemImage: proposal.advice.status == .suggest ? "text.bubble" : "info.circle")
                    .font(.headline)
                Spacer(minLength: 8)
                Text(proposal.scope.isPassage ? "所选短段落" : proposal.scope.target.kind == .explicitSelection ? "只改选区" : "当前句子")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    section("原文", text: proposal.request.sentence)
                    if proposal.advice.status == .suggest {
                        section("建议", text: proposal.suggestedSentence)
                        if !proposal.changes.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("修改").font(.caption).foregroundStyle(.secondary)
                                diff.font(.callout).accessibilityHidden(true)
                                Text(diffSummary).font(.caption).foregroundStyle(.secondary)
                                    .accessibilityLabel("修改摘要：\(diffSummary)")
                            }
                        }
                    } else {
                        Text(proposal.advice.message.isEmpty ? "这句已经合适，可以继续写。" : proposal.advice.message)
                            .font(.body).fixedSize(horizontal: false, vertical: true)
                    }
                    if proposal.advice.status == .suggest {
                        explanationSection
                    }
                    if proposal.scope.context.text != proposal.request.sentence {
                        section("参考语境", text: proposal.scope.context.text)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if proposal.advice.status == .suggest {
                switch explanationController.state {
                case .loaded:
                    EmptyView()
                default:
                    Button(action: explanationController.start) {
                        switch explanationController.state {
                        case .loading:
                            Label("正在解释…", systemImage: "hourglass")
                        case .failed, .unavailable:
                            Label("再次请求解释", systemImage: "arrow.clockwise")
                        default:
                            Label("为什么这样改？", systemImage: "lightbulb")
                        }
                    }
                    .disabled(explanationController.state == .loading)
                    .frame(minHeight: 38)
                    .accessibilityHint("主动请求本次修改的简短解释，不会改变建议")
                }
            }
            HStack(spacing: 8) {
                Text(proposal.snapshot.applicationIdentifier == "com.apple.TextEdit"
                    ? "接受后可在编辑器按 ⌘Z 撤销" : "由原编辑器处理粘贴、样式与撤销")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("收起", action: onDismiss).frame(minWidth: 60, minHeight: 44)
                if proposal.advice.status == .suggest {
                    Button("接受 ⌃⌥↩", action: onAccept)
                        .buttonStyle(.borderedProminent).frame(minHeight: 44)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var explanationSection: some View {
        switch explanationController.state {
        case .loaded(let explanation):
            VStack(alignment: .leading, spacing: 6) {
                Text("为什么这样改").font(.caption).foregroundStyle(.secondary)
                Text(explanation.reason).font(.body).fixedSize(horizontal: false, vertical: true)
                if !explanation.acceptableVariants.isEmpty {
                    Text("可用变体：\(explanation.acceptableVariants.joined(separator: "、"))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        case .unavailable:
            Text("这次建议暂时没有可用解释；仍可接受。")
                .font(.caption).foregroundStyle(.secondary)
        case .failed:
            Text("解释暂时失败；仍可接受。")
                .font(.caption).foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    private func section(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(text).font(.body).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var diff: Text {
        proposal.changes.reduce(Text("")) { result, segment in
            let text: Text
            switch segment.kind {
            case .unchanged: text = Text(segment.text)
            case .removed: text = Text(segment.text).strikethrough().foregroundColor(.red)
            case .inserted: text = Text(segment.text).underline().foregroundColor(.green)
            }
            return result + text
        }
    }

    private var diffSummary: String {
        let changes = proposal.changes.compactMap { segment -> String? in
            let value = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            switch segment.kind {
            case .unchanged: return nil
            case .removed: return "删除“\(value)”"
            case .inserted: return "插入“\(value)”"
            }
        }
        return changes.isEmpty ? "原文结构保持不变" : changes.joined(separator: "；")
    }
}
