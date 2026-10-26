import AppKit
import CoachCore
import SwiftUI

private final class NonActivatingReadingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A reading surface, deliberately without any edit or accept action.
@MainActor
final class ReadingPanel {
    private var panel: NSPanel?
    func hide() { panel?.orderOut(nil) }

    func show(request: ReadingRequest, explanation: ReadingExplanation, anchor: CGRect?,
              onDismiss: @escaping @MainActor () -> Void) {
        let visibleText = request.selection.count + explanation.meaning.count + explanation.contextMeaning.count
            + explanation.usage.count
        let height = min(480, max(330, 270 + CGFloat((visibleText + 49) / 50) * 20))
        let frame = PanelPlacement.frame(anchor: anchor, preferredSize: NSSize(width: 460, height: height))
        let panel = self.panel ?? NonActivatingReadingPanel(contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating; panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
        panel.hasShadow = true; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: ReadingView(request: request, explanation: explanation, onDismiss: onDismiss))
        // Missing AX bounds may use the pointer for a read-only card, never as an edit address.
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless(); self.panel = panel
        NSAccessibility.post(element: panel, notification: .announcementRequested,
                             userInfo: [.announcement: "语境解释已显示，只读。"])
    }
}

private struct ReadingView: View {
    let request: ReadingRequest
    let explanation: ReadingExplanation
    let onDismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("语境解释", systemImage: "text.magnifyingglass").font(.headline)
                Spacer()
                Button("关闭", action: onDismiss).frame(minWidth: 60, minHeight: 44)
                    .accessibilityLabel("关闭语境解释")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    section("选中内容", text: request.selection)
                    if request.contextKind == .selectionOnly {
                        Text("仅解释选中文字；未取得周围语境。").font(.caption).foregroundStyle(.secondary)
                    } else if request.contextKind == .excerpt {
                        Text("依据读取到的片段解释；上下文可能不完整。").font(.caption).foregroundStyle(.secondary)
                    }
                    section("中文含义", text: explanation.meaning)
                    if request.contextKind != .selectionOnly {
                        section("所在语境", text: request.context)
                        section("语境中的理解", text: explanation.contextMeaning)
                    }
                    if !explanation.usage.isEmpty {
                        section("用法", text: explanation.usage)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("只读 · Esc / ⌃⌥. 收起").font(.caption).foregroundStyle(.secondary)
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
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
