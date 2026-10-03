import AppKit
import SwiftUI

@MainActor
final class InlineCandidatePanel {
    private var panel: NSPanel?

    func hide() { panel?.orderOut(nil) }

    func show(text: String, anchor: CGRect, canAccept: Bool,
              onAccept: @escaping @MainActor () -> Void,
              onLearn: @escaping @MainActor () -> Void,
              onCopy: @escaping @MainActor () -> Void,
              onDismiss: @escaping @MainActor () -> Void) {
        let panel = self.panel ?? NSPanel(contentRect: NSRect(x: 0, y: 0, width: 390, height: 72),
                                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: CandidateView(text: text, canAccept: canAccept,
            onAccept: onAccept, onLearn: onLearn, onCopy: onCopy, onDismiss: onDismiss))
        // AX reports coordinates from the top-left of the primary screen.
        let desktopTop = NSScreen.screens.first?.frame.maxY ?? 0
        let caret = NSRect(x: anchor.minX, y: desktopTop - anchor.maxY, width: anchor.width, height: anchor.height)
        let screen = NSScreen.screens.first { $0.frame.intersects(caret) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        let x = min(max(caret.minX, area.minX + 8), area.maxX - 398)
        let y = caret.minY - 78 >= area.minY ? caret.minY - 78 : min(caret.maxY + 6, area.maxY - 80)
        panel.setFrame(NSRect(x: x, y: y, width: 390, height: 72), display: true)
        panel.orderFrontRegardless() // Never make key or activate: editor keeps input focus.
        self.panel = panel
    }
}

private struct CandidateView: View {
    let text: String
    let canAccept: Bool
    let onAccept: () -> Void
    let onLearn: () -> Void
    let onCopy: () -> Void
    let onDismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(text).font(.system(size: 14, weight: .medium)).lineLimit(1)
            HStack(spacing: 12) {
                if canAccept { Button("接受 ⌃⌥↩", action: onAccept) }
                else { Button("复制", action: onCopy) }
                Button("学习 ⌃⌥K", action: onLearn)
                Spacer()
                Button("收起", action: onDismiss)
            }.font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(.secondary)
        }.padding(12).frame(width: 390, height: 72)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.12)))
    }
}
