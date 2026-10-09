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
  func show(_ message: String, near button: NSStatusBarButton?, persistent: Bool = false) {
    hide()
    let area = button?.window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
    let panel =
      self.panel
      ?? NoticePanel(
        contentRect: NSRect(x: 0, y: 0, width: 340, height: 70),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    panel.contentView = NSHostingView(
      rootView: Text(message).font(.system(size: 12))
        .padding(12).frame(width: 340, height: 70, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)))
    let x = min(
      max((button?.window?.frame.midX ?? area.maxX) - 170, area.minX + 8), area.maxX - 348)
    panel.setFrame(NSRect(x: x, y: area.maxY - 78, width: 340, height: 70), display: true)
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
