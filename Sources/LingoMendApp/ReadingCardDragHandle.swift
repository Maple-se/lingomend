import AppKit
import SwiftUI

struct ReadingCardDragHandle: NSViewRepresentable {
    let onEvent: (ReadingCardDragEvent) -> Void

    func makeNSView(context: Context) -> ReadingCardDragHandleView {
        let view = ReadingCardDragHandleView()
        view.onEvent = onEvent
        return view
    }

    func updateNSView(_ nsView: ReadingCardDragHandleView, context: Context) {
        nsView.onEvent = onEvent
    }
}

final class ReadingCardDragHandleView: NSView {
    var onEvent: ((ReadingCardDragEvent) -> Void)?

    private var startMouseLocation: NSPoint?
    private var startWindowOrigin: NSPoint?
    private var hasMoved = false

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        startMouseLocation = NSEvent.mouseLocation
        startWindowOrigin = window.frame.origin
        hasMoved = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let startMouseLocation, let startWindowOrigin else { return }
        let current = NSEvent.mouseLocation
        let delta = NSPoint(x: current.x - startMouseLocation.x,
                            y: current.y - startMouseLocation.y)
        if !hasMoved, hypot(delta.x, delta.y) < 3 { return }
        if !hasMoved {
            hasMoved = true
            onEvent?(.began)
        }
        let proposed = NSRect(origin: NSPoint(x: startWindowOrigin.x + delta.x,
                                               y: startWindowOrigin.y + delta.y),
                               size: window.frame.size)
        let screens = NSScreen.screens.map {
            PanelPlacement.Display(frame: $0.frame, visibleFrame: $0.visibleFrame)
        }
        let constrained = PanelPlacement.clampedFrame(proposed, to: screens, pointer: current)
        window.setFrameOrigin(constrained.origin)
    }

    override func mouseUp(with event: NSEvent) {
        if hasMoved { onEvent?(.ended) }
        startMouseLocation = nil
        startWindowOrigin = nil
        hasMoved = false
    }
}
