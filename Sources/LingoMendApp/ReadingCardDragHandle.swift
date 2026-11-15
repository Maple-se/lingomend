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
    private var startWindowFrame: NSRect?
    private var hasMoved = false

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        startMouseLocation = NSEvent.mouseLocation
        startWindowFrame = window.frame
        hasMoved = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let startMouseLocation, let startWindowFrame else { return }
        let current = NSEvent.mouseLocation
        let delta = NSPoint(x: current.x - startMouseLocation.x,
                            y: current.y - startMouseLocation.y)
        if !hasMoved, hypot(delta.x, delta.y) < 3 { return }
        if !hasMoved {
            hasMoved = true
            onEvent?(.began)
        }
        let proposed = startWindowFrame.offsetBy(dx: delta.x, dy: delta.y)
        let constrained = PanelPlacement.clampedFrame(proposed, to: PanelPlacement.connectedDisplays, pointer: current)
        if constrained.size == window.frame.size {
            window.setFrameOrigin(constrained.origin)
        } else {
            window.setFrame(constrained, display: true)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if hasMoved { onEvent?(.ended) }
        startMouseLocation = nil
        startWindowFrame = nil
        hasMoved = false
    }
}
