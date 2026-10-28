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
    private var explanationController: WritingExplanationController?

    var explanation: WritingExplanation? { explanationController?.explanation }

    func hide() {
        explanationController?.cancel(); explanationController = nil
        panel?.orderOut(nil)
    }

    func show(_ proposal: SentenceProposal, anchor: CGRect, onAccept: @escaping @MainActor () -> Void,
              onDismiss: @escaping @MainActor () -> Void,
              onExplain: @escaping @MainActor () async throws -> WritingExplanation?) {
        let visibleText = proposal.request.sentence.count +
            (proposal.advice.status == .suggest ? proposal.suggestedSentence.count : proposal.advice.message.count)
        let lines = CGFloat(max(2, (visibleText + 47) / 48))
        let height = min(440, max(260, 190 + lines * 24))
        let frame = PanelPlacement.frame(anchor: anchor, preferredSize: NSSize(width: 470, height: height))
        let panel = self.panel ?? NonActivatingSentencePanel(contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating; panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
        panel.hasShadow = true; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let explanationController = WritingExplanationController(action: onExplain)
        panel.contentView = NSHostingView(rootView: SentenceCandidateView(
            proposal: proposal, explanationController: explanationController,
            onAccept: onAccept, onDismiss: onDismiss))
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        self.explanationController = explanationController
        NSAccessibility.post(element: panel, notification: .announcementRequested,
                             userInfo: [.announcement: proposal.advice.status == .suggest
                                ? "写作建议已显示。请核对原文和建议，按 Control Option Return 接受。"
                                : "写作反馈已显示。"])
        self.panel = panel
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
        .modifier(CandidateCardSurface())
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
