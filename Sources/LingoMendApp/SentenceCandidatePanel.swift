import AppKit
import CoachCore
import MVPFlow
import SwiftUI

private final class NonActivatingSentencePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class SentenceCandidatePanel {
    private var panel: NSPanel?
    func hide() { panel?.orderOut(nil) }

    func show(_ proposal: SentenceProposal, anchor: CGRect, onAccept: @escaping @MainActor () -> Void,
              onDismiss: @escaping @MainActor () -> Void) {
        let width: CGFloat = 450, height: CGFloat = 240
        let panel = self.panel ?? NonActivatingSentencePanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating; panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
        panel.hasShadow = true; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: SentenceCandidateView(proposal: proposal, onAccept: onAccept, onDismiss: onDismiss))
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let caret = NSRect(x: anchor.minX, y: top - anchor.maxY, width: anchor.width, height: anchor.height)
        let area = (NSScreen.screens.first { $0.frame.intersects(caret) } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        let x = min(max(caret.minX, area.minX + 8), area.maxX - width - 8)
        let y = caret.minY - height - 6 >= area.minY ? caret.minY - height - 6
            : min(caret.maxY + 6, area.maxY - height - 8)
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        panel.orderFrontRegardless()
        self.panel = panel
    }
}

private struct SentenceCandidateView: View {
    let proposal: SentenceProposal
    let onAccept: () -> Void
    let onDismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(proposal.label).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(proposal.scope.target.kind == .explicitSelection ? "只改选区" : "当前句子")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("读取语境：\(proposal.scope.context.text)").font(.caption).foregroundStyle(.secondary)
                    if proposal.advice.status == .suggest {
                        Text(proposal.suggestedSentence).font(.system(size: 14, weight: .medium))
                        Text("修改对照").font(.caption).foregroundStyle(.secondary)
                        diff.font(.system(size: 12))
                    } else {
                        Text(proposal.advice.message.isEmpty ? "这句已经合适，可以继续写。" : proposal.advice.message)
                            .font(.system(size: 14))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Text("明确接受才写回 · ⌘Z 原生撤销").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("取消", action: onDismiss).buttonStyle(.plain).font(.caption)
                if proposal.advice.status == .suggest {
                    Button("接受 ⌃⌥↩", action: onAccept).buttonStyle(.borderedProminent).font(.caption)
                }
            }
        }.padding(12).frame(width: 450, height: 240)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.12)))
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
}
