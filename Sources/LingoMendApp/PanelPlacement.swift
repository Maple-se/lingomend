import AppKit

/// AX bounds use the primary display's top-left origin; AppKit uses a bottom-left origin.
@MainActor
enum PanelPlacement {
    struct Display {
        let frame: NSRect
        let visibleFrame: NSRect
    }

    static var connectedDisplays: [Display] {
        NSScreen.screens.map { Display(frame: $0.frame, visibleFrame: $0.visibleFrame) }
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
                             displays: [Display]) -> NSRect? {
        let target = anchor.map {
            NSRect(x: $0.minX, y: primaryTop - $0.maxY,
                width: max($0.width, 1), height: max($0.height, 1))
        } ?? NSRect(origin: fallback, size: NSSize(width: 1, height: 1))
        guard let display = display(containing: target, in: displays) else { return nil }
        let area = display.visibleFrame.insetBy(dx: 12, dy: 12)
        let protected = target.insetBy(dx: -12, dy: -12)
        let sides: [(edge: CGRectEdge, space: CGFloat)] = [
            (.minYEdge, protected.minY - area.minY),
            (.maxYEdge, area.maxY - protected.maxY),
            (.maxXEdge, area.maxX - protected.maxX),
            (.minXEdge, protected.minX - area.minX)
        ]
        // Each strip lies wholly outside the padded selection. Fit along the
        // edge first, reducing dimensions only when no full-size card fits.
        let candidates = sides.enumerated().compactMap { index, side -> (frame: NSRect, score: CGFloat)? in
            guard side.space > 0 else { return nil }
            let acrossWidth = side.edge == .minXEdge || side.edge == .maxXEdge
            let limit = acrossWidth ? area.width : area.height
            let strip = area.divided(atDistance: min(limit, side.space), from: side.edge).slice
            let size = NSSize(width: min(preferredSize.width, strip.width),
                              height: min(preferredSize.height, strip.height))
            let minimumSize = ReadingCardLayout.minimumPanelSize
            guard size.width >= minimumSize.width, size.height >= minimumSize.height else { return nil }
            let x = switch side.edge {
            case .minXEdge: strip.maxX - size.width
            case .maxXEdge: strip.minX
            default: min(max(target.minX, strip.minX), strip.maxX - size.width)
            }
            let y = switch side.edge {
            case .minYEdge: strip.maxY - size.height
            case .maxYEdge: strip.minY
            default: min(max(target.midY - size.height / 2, strip.minY), strip.maxY - size.height)
            }
            let frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
            return (frame, candidateScore(frame, sideRank: sides.count - index, anchor: target))
        }
        return candidates.max {
            let leftArea = $0.frame.width * $0.frame.height
            let rightArea = $1.frame.width * $1.frame.height
            return leftArea == rightArea ? $0.score < $1.score : leftArea < rightArea
        }?.frame
    }

    static func clampedFrame(_ frame: NSRect, to displays: [Display],
                             pointer: NSPoint? = nil) -> NSRect {
        let pointerDisplay = pointer.flatMap { point in displays.first { $0.frame.contains(point) } }
        guard let display = pointerDisplay ?? display(containing: frame, in: displays) else { return frame }
        let area = display.visibleFrame.insetBy(dx: 12, dy: 12)
        let width = min(frame.width, area.width)
        let height = min(frame.height, area.height)
        let x = min(max(frame.minX, area.minX), area.maxX - width)
        let y = min(max(frame.maxY - height, area.minY), area.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private static func display(containing target: NSRect, in displays: [Display]) -> Display? {
        displays.max { lhs, rhs in
            let lhsArea = lhs.frame.intersection(target)
            let rhsArea = rhs.frame.intersection(target)
            let leftArea = lhsArea.width * lhsArea.height
            let rightArea = rhsArea.width * rhsArea.height
            if leftArea != rightArea { return leftArea < rightArea }
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
