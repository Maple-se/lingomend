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

    static func readingFrame(anchor: CGRect?, preferredSize: NSSize,
                             fallback: NSPoint = NSEvent.mouseLocation,
                             primaryTop: CGFloat,
                             displays: [Display],
                             edgeInset: CGFloat = 8,
                             anchorInset: CGFloat = 12,
                             gap: CGFloat = 12) -> NSRect {
        guard let anchor else {
            return frame(anchor: nil, preferredSize: preferredSize, fallback: fallback,
                primaryTop: primaryTop, displays: displays)
        }
        let target = NSRect(x: anchor.minX, y: primaryTop - anchor.maxY,
            width: max(anchor.width, 1), height: max(anchor.height, 1))
        guard let display = display(containing: target, in: displays) else {
            return frame(anchor: anchor, preferredSize: preferredSize, fallback: fallback,
                primaryTop: primaryTop, displays: displays)
        }
        let area = display.visibleFrame.insetBy(dx: edgeInset, dy: edgeInset)
        let size = constrainedSize(preferredSize, in: area)
        let protectedAnchor = target.insetBy(dx: -anchorInset, dy: -anchorInset)
        let candidates: [(NSRect, Int)] = [
            (NSRect(x: target.minX, y: target.minY - size.height - gap,
                width: size.width, height: size.height), 4),
            (NSRect(x: target.minX, y: target.maxY + gap,
                width: size.width, height: size.height), 3),
            (NSRect(x: target.maxX + gap, y: target.midY - size.height / 2,
                width: size.width, height: size.height), 2),
            (NSRect(x: target.minX - size.width - gap, y: target.midY - size.height / 2,
                width: size.width, height: size.height), 1)
        ]
        let viable = candidates.filter { candidate, _ in
            area.contains(candidate) && !candidate.intersects(protectedAnchor)
        }
        if let best = viable.max(by: { lhs, rhs in
            candidateScore(lhs.0, sideRank: lhs.1, anchor: target) <
                candidateScore(rhs.0, sideRank: rhs.1, anchor: target)
        }) {
            return best.0
        }

        // A very large card may leave no complete candidate. Keep the old
        // edge-safe placement as a bounded fallback and let the content scroll.
        return frame(anchor: anchor, preferredSize: preferredSize, fallback: fallback,
            primaryTop: primaryTop, displays: displays)
    }

    static func clampedFrame(_ frame: NSRect, to displays: [Display],
                             pointer: NSPoint? = nil, edgeInset: CGFloat = 8) -> NSRect {
        guard let display = display(containing: frame, pointer: pointer, in: displays) else {
            return frame
        }
        let area = display.visibleFrame.insetBy(dx: edgeInset, dy: edgeInset)
        let width = min(frame.width, area.width)
        let height = min(frame.height, area.height)
        let x = min(max(frame.minX, area.minX), area.maxX - width)
        let y = min(max(frame.minY, area.minY), area.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private static func constrainedSize(_ size: NSSize, in area: NSRect) -> NSSize {
        NSSize(width: min(size.width, area.width), height: min(size.height, area.height))
    }

    private static func display(containing target: NSRect, in displays: [Display]) -> Display? {
        display(containing: target, pointer: nil, in: displays)
    }

    private static func display(containing target: NSRect, pointer: NSPoint?, in displays: [Display]) -> Display? {
        displays.max { lhs, rhs in
            let lhsArea = lhs.frame.intersection(target)
            let rhsArea = rhs.frame.intersection(target)
            let leftArea = lhsArea.width * lhsArea.height
            let rightArea = rhsArea.width * rhsArea.height
            if leftArea != rightArea { return leftArea < rightArea }
            if let pointer {
                let leftDistance = distanceSquared(from: pointer, to: lhs.frame)
                let rightDistance = distanceSquared(from: pointer, to: rhs.frame)
                if leftDistance != rightDistance { return leftDistance > rightDistance }
            }
            return distanceSquared(from: target.origin, to: lhs.frame) >
                distanceSquared(from: target.origin, to: rhs.frame)
        }
    }

    private static func candidateScore(_ candidate: NSRect, sideRank: Int,
                                      anchor: NSRect) -> CGFloat {
        let dx = candidate.midX - anchor.midX
        let dy = candidate.midY - anchor.midY
        let distancePenalty = (dx * dx + dy * dy) / 1_000_000
        return CGFloat(sideRank) - distancePenalty
    }

    private static func distanceSquared(from point: NSPoint, to rect: NSRect) -> CGFloat {
        let x = min(max(point.x, rect.minX), rect.maxX)
        let y = min(max(point.y, rect.minY), rect.maxY)
        let dx = point.x - x, dy = point.y - y
        return dx * dx + dy * dy
    }
}
