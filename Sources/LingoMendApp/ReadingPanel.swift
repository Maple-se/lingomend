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
        let size = NSSize(width: 440, height: 330)
        let panel = self.panel ?? NonActivatingReadingPanel(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating; panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
        panel.hasShadow = true; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: ReadingView(request: request, explanation: explanation, onDismiss: onDismiss))
        // Missing AX bounds may use the pointer for a read-only card, never as an edit address.
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let selection = anchor.map { NSRect(x: $0.minX, y: top - $0.maxY, width: $0.width, height: $0.height) }
            ?? NSRect(origin: NSEvent.mouseLocation, size: NSSize(width: 1, height: 1))
        let area = (NSScreen.screens.first { $0.frame.intersects(selection) } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        let x = min(max(selection.minX, area.minX + 8), area.maxX - size.width - 8)
        let y = selection.minY - size.height - 8 >= area.minY ? selection.minY - size.height - 8
            : min(selection.maxY + 8, area.maxY - size.height - 8)
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
        panel.orderFrontRegardless(); self.panel = panel
    }
}

private struct ReadingView: View {
    let request: ReadingRequest
    let explanation: ReadingExplanation
    let onDismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("语境解释").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Button(action: onDismiss) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(.plain).accessibilityLabel("关闭语境解释")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(request.selection).font(.system(size: 17, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if request.contextKind == .selectionOnly {
                        Text("仅解释选中文字；未取得周围语境。").font(.caption).foregroundStyle(.secondary)
                    } else if request.contextKind == .excerpt {
                        Text("依据读取到的片段解释；上下文可能不完整。").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(explanation.meaning).font(.system(size: 14)).lineSpacing(3)
                    if request.contextKind != .selectionOnly {
                        Divider()
                        Text(request.context).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(2)
                        Text(explanation.contextMeaning).font(.system(size: 13)).lineSpacing(3)
                    }
                    if !explanation.usage.isEmpty {
                        Text(explanation.usage).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(2)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("只读解释 · Esc / ⌃⌥. 关闭").font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(14).frame(width: 440, height: 330)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.12)))
    }
}
