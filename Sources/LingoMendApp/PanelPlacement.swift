import AppKit

/// AX bounds use the primary display's top-left origin; AppKit uses a bottom-left origin.
@MainActor
enum PanelPlacement {
    struct Display {
        let frame: NSRect
        let visibleFrame: NSRect
    }

    static func frame(anchor: CGRect?, preferredSize: NSSize, fallback: NSPoint = NSEvent.mouseLocation) -> NSRect {
        let screens = NSScreen.screens
        return frame(anchor: anchor, preferredSize: preferredSize, fallback: fallback,
            primaryTop: screens.first?.frame.maxY ?? 0,
            displays: screens.map { Display(frame: $0.frame, visibleFrame: $0.visibleFrame) })
    }

    static func frame(anchor: CGRect?, preferredSize: NSSize, fallback: NSPoint,
                      primaryTop: CGFloat, displays: [Display]) -> NSRect {
        let target = anchor.map {
            NSRect(x: $0.minX, y: primaryTop - $0.maxY,
                   width: max($0.width, 1), height: max($0.height, 1))
        } ?? NSRect(origin: fallback, size: NSSize(width: 1, height: 1))
        let display = displays.max { lhs, rhs in
            let left = lhs.frame.intersection(target), right = rhs.frame.intersection(target)
            let leftArea = left.width * left.height, rightArea = right.width * right.height
            if leftArea != rightArea { return leftArea < rightArea }
            return distanceSquared(from: target.origin, to: lhs.frame) >
                distanceSquared(from: target.origin, to: rhs.frame)
        }
        let area = display?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        let width = min(preferredSize.width, max(240, area.width - 16))
        let height = min(preferredSize.height, max(160, area.height - 16))
        let x = min(max(target.minX, area.minX + 8), area.maxX - width - 8)
        let below = target.minY - height - 8
        let above = target.maxY + 8
        let y = below >= area.minY + 8 ? below :
            (above + height <= area.maxY - 8 ? above : min(max(below, area.minY + 8), area.maxY - height - 8))
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private static func distanceSquared(from point: NSPoint, to rect: NSRect) -> CGFloat {
        let x = min(max(point.x, rect.minX), rect.maxX)
        let y = min(max(point.y, rect.minY), rect.maxY)
        let dx = point.x - x, dy = point.y - y
        return dx * dx + dy * dy
    }
}
