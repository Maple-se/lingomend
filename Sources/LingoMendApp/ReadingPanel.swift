import AppKit
import CoachCore
import SwiftUI

private final class NonActivatingReadingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

enum ReadingCardPresentationState: Equatable {
    case hidden
    case shownAutomatically
    case shownManually
    case dragging
    case pinned
    case draggingPinned
}

enum ReadingCardLayout {
    static let baseHeaderHeight: CGFloat = 56
    static let maximumHeaderHeight: CGFloat = 64
    static let minimumControlHeight: CGFloat = 44

    static var headerHeight: CGFloat {
        let headlineSize = NSFont.preferredFont(forTextStyle: .headline).pointSize
        return min(maximumHeaderHeight, max(baseHeaderHeight, ceil(headlineSize + 28)))
    }
}

enum ReadingCardDragEvent {
    case began
    case ended
}

/// A reading surface, deliberately without any edit or accept action.
@MainActor
final class ReadingPanel {
    private var panel: NSPanel?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var outsideClickHandler: (@MainActor () -> Void)?
    private var isPinned = false
    private(set) var state: ReadingCardPresentationState = .hidden

    func hide() {
        removeClickMonitors()
        panel?.orderOut(nil)
        outsideClickHandler = nil
        isPinned = false
        state = .hidden
    }

    func show(request: ReadingRequest, explanation: ReadingExplanation, anchor: CGRect?,
              onDismiss: @escaping @MainActor () -> Void,
              onOutsideClick: @escaping @MainActor () -> Void) {
        let visibleText = request.selection.count + explanation.meaning.count + explanation.contextMeaning.count
            + explanation.usage.count
        let height = min(480, max(330, 270 + CGFloat((visibleText + 49) / 50) * 20))
        let screens = NSScreen.screens
        let frame = PanelPlacement.readingFrame(anchor: anchor,
            preferredSize: NSSize(width: 460, height: height),
            primaryTop: screens.first?.frame.maxY ?? 0,
            displays: screens.map { PanelPlacement.Display(frame: $0.frame, visibleFrame: $0.visibleFrame) })
        let panel = self.panel ?? NonActivatingReadingPanel(contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating; panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
        panel.hasShadow = true; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        state = .shownAutomatically
        panel.contentView = NSHostingView(rootView: ReadingView(request: request, explanation: explanation,
            onDismiss: onDismiss, onDragEvent: { [weak self] event in self?.handleDragEvent(event) }))
        // Missing AX bounds may use the pointer for a read-only card, never as an edit address.
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless(); self.panel = panel
        outsideClickHandler = onOutsideClick
        installClickMonitors()
        NSAccessibility.post(element: panel, notification: .announcementRequested,
                             userInfo: [.announcement: "语境解释已显示，只读。"])
    }

    private func installClickMonitors() {
        removeClickMonitors()
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.handleOutsideClick(at: NSEvent.mouseLocation) }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
            [weak self] event in
            MainActor.assumeIsolated {
                self?.handleOutsideClick(at: NSEvent.mouseLocation)
            }
            return event
        }
    }

    private func removeClickMonitors() {
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
    }

    private func handleOutsideClick(at location: NSPoint) {
        guard state != .hidden, !isPinned, let panel, panel.isVisible,
              !panel.frame.contains(location) else { return }
        outsideClickHandler?()
    }

    private func handleDragEvent(_ event: ReadingCardDragEvent) {
        switch event {
        case .began:
            if state == .shownAutomatically || state == .shownManually { state = .dragging }
        case .ended:
            if state == .dragging { state = .shownManually }
        }
    }
}

private struct ReadingView: View {
    let request: ReadingRequest
    let explanation: ReadingExplanation
    let onDismiss: () -> Void
    let onDragEvent: (ReadingCardDragEvent) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ReadingCardHeader(onDismiss: onDismiss, onDragEvent: onDragEvent)
            Divider().opacity(0.65)
                .accessibilityHidden(true)
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
                .padding(.top, 10)
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

private struct ReadingCardHeader: View {
    let onDismiss: () -> Void
    let onDragEvent: (ReadingCardDragEvent) -> Void

    var body: some View {
        ZStack {
            ReadingCardDragHandle(onEvent: onDragEvent)
                .accessibilityLabel("移动语境解释卡片")
            HStack(spacing: 10) {
                Label("语境解释", systemImage: "text.magnifyingglass")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Button("关闭", action: onDismiss)
                    .frame(minWidth: 60, minHeight: ReadingCardLayout.minimumControlHeight)
                    .accessibilityLabel("关闭语境解释")
            }
        }
        .frame(maxWidth: .infinity, minHeight: ReadingCardLayout.headerHeight,
               maxHeight: ReadingCardLayout.maximumHeaderHeight, alignment: .center)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("语境解释标题栏")
    }
}
