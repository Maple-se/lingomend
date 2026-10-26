import AppKit
import SwiftUI

/// Brief, non-activating feedback after explicit user actions, never idle suggestions.
@MainActor
final class RequestNotice {
  private var panel: NSPanel?
  private var hideTask: Task<Void, Never>?
  func hide() {
    hideTask?.cancel()
    hideTask = nil
    panel?.orderOut(nil)
  }
  func show(_ message: String, near button: NSStatusBarButton?, persistent: Bool = false,
            actionTitle: String? = nil, action: (@MainActor () -> Void)? = nil) {
    hide()
    let area = button?.window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
    let width: CGFloat = min(380, max(280, area.width - 16))
    let height: CGFloat = action == nil ? 96 : 132
    let panel =
      self.panel
      ?? NoticePanel(
        contentRect: NSRect(x: 0, y: 0, width: width, height: height),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    panel.contentView = NSHostingView(
      rootView: VStack(alignment: .leading, spacing: 8) {
        Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
        if let actionTitle, let action {
          Button(actionTitle, action: action).frame(minHeight: 44)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
      .padding(12)
      .frame(width: width, height: height)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)))
    let x = min(
      max((button?.window?.frame.midX ?? area.maxX) - width / 2, area.minX + 8), area.maxX - width - 8)
    panel.setFrame(NSRect(x: x, y: area.maxY - height - 8, width: width, height: height), display: true)
    panel.orderFrontRegardless()
    self.panel = panel
    if !persistent {
      hideTask = Task { @MainActor [weak self] in
        do {
          try await Task.sleep(for: .seconds(5))
          self?.panel?.orderOut(nil)
        } catch {}
      }
    }
  }
}

private final class NoticePanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}
