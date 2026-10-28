import AppKit
import MVPFlow
import SwiftUI

private final class NonActivatingRecentSuggestionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class RecentSuggestionPanel {
    private var panel: NSPanel?

    func hide() { panel?.orderOut(nil) }

    func show(_ suggestion: RecentAcceptedSuggestion, onDismiss: @escaping @MainActor () -> Void) {
        let visibleText = suggestion.original.count + suggestion.accepted.count
            + (suggestion.explanation?.reason.count ?? 0)
        let height = min(460, max(300, 220 + CGFloat((visibleText + 59) / 60) * 20))
        let area = NSScreen.main?.visibleFrame ?? .zero
        let frame = NSRect(x: area.midX - 230, y: area.midY - height / 2,
                           width: 460, height: height)
        let panel = self.panel ?? NonActivatingRecentSuggestionPanel(
            contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = .floating; panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
        panel.hasShadow = true; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: RecentSuggestionView(
            suggestion: suggestion, onDismiss: onDismiss))
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless(); self.panel = panel
        NSAccessibility.post(element: panel, notification: .announcementRequested,
                             userInfo: [.announcement: "最近一次 LingoMend 建议已显示，只读。"])
    }
}

private struct RecentSuggestionView: View {
    let suggestion: RecentAcceptedSuggestion
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("最近一次建议", systemImage: "clock.arrow.circlepath").font(.headline)
                Spacer()
                Button("关闭", action: onDismiss).frame(minWidth: 60, minHeight: 44)
                    .accessibilityLabel("关闭最近一次建议")
            }
            Text(suggestion.extentLabel).font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    section("接受前", text: suggestion.original)
                    section("接受后", text: suggestion.accepted)
                    if let explanation = suggestion.explanation {
                        section("为什么这样改", text: explanation.reason)
                        if !explanation.acceptableVariants.isEmpty {
                            section("可用变体", text: explanation.acceptableVariants.joined(separator: "、"))
                        }
                    } else {
                        Text("这次接受时没有请求解释。下次候选出现时，可以主动查看修改原因。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("只读 · 仅保留本次会话的最近一条建议")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.primary.opacity(0.15)))
    }

    private func section(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(text).font(.body).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
