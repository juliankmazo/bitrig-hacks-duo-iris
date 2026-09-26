import CoreGraphics
import SwiftUI

/// Fold-aware 4x3 grid geometry. Recomputed on every layout pass from the live
/// reserved regions (never cached: they are empty on the first pass).
struct GridLayout: Equatable {
    static let columns = 4
    static let rows = 3

    var size: CGSize
    var cells: [CGRect]
    var header: CGRect
    /// The fold gap between column 2 and 3 when a vertical division is active.
    var foldGap: CGRect?

    static func make(size: CGSize,
                     divisions: [ReservedRegion],
                     occlusions: [ReservedRegion],
                     headerHeight: CGFloat = 96) -> GridLayout {
        let outer: CGFloat = 16
        let gap: CGFloat = 12

        // Inset for occlusions (inner camera): push the nearest edge past the region + margins.
        var top = outer, bottom = outer, left = outer, right = outer
        for r in occlusions where r.isActive {
            let f = r.frame
            let m = r.margins
            let dTop = f.minY, dBottom = size.height - f.maxY
            let dLeft = f.minX, dRight = size.width - f.maxX
            // Cameras sit in a corner/edge: prefer giving up a strip of height (keeps 4 even
            // columns) unless the region is tall and thin along a side.
            let isTallSideRegion = f.height > size.height / 3
            if !isTallSideRegion {
                if dTop <= dBottom { top = max(top, f.maxY + m.bottom) }
                else { bottom = max(bottom, size.height - f.minY + m.top) }
            } else if dLeft <= dRight {
                left = max(left, f.maxX + m.trailing)
            } else {
                right = max(right, size.width - f.minX + m.leading)
            }
        }

        let content = CGRect(x: left, y: top,
                             width: max(0, size.width - left - right),
                             height: max(0, size.height - top - bottom))
        let header = CGRect(x: content.minX, y: content.minY, width: content.width, height: headerHeight)
        let gridY = content.minY + headerHeight + gap
        let gridH = max(0, content.maxY - gridY)
        let rowH = max(0, (gridH - gap * CGFloat(rows - 1)) / CGFloat(rows))

        // Vertical fold (book pose): 2 columns per side, the gap widened to clear the crease.
        let fold = divisions.first { $0.isActive && $0.frame.height >= $0.frame.width && $0.frame.width > 0 }
        var xs: [(CGFloat, CGFloat)] = []  // (minX, width) per column
        var foldGap: CGRect?
        if let fold, fold.frame.midX > content.minX, fold.frame.midX < content.maxX {
            let leftEnd = min(fold.frame.minX - max(fold.margins.leading, gap / 2), content.maxX)
            let rightStart = max(fold.frame.maxX + max(fold.margins.trailing, gap / 2), content.minX)
            let lw = max(0, (leftEnd - content.minX - gap) / 2)
            let rw = max(0, (content.maxX - rightStart - gap) / 2)
            xs = [(content.minX, lw), (content.minX + lw + gap, lw),
                  (rightStart, rw), (rightStart + rw + gap, rw)]
            foldGap = CGRect(x: leftEnd, y: gridY, width: rightStart - leftEnd, height: gridH)
        } else {
            let cw = max(0, (content.width - gap * CGFloat(columns - 1)) / CGFloat(columns))
            xs = (0..<columns).map { (content.minX + CGFloat($0) * (cw + gap), cw) }
        }

        var cells: [CGRect] = []
        for r in 0..<rows {
            for c in 0..<columns {
                cells.append(CGRect(x: xs[c].0, y: gridY + CGFloat(r) * (rowH + gap),
                                    width: xs[c].1, height: rowH))
            }
        }
        return GridLayout(size: size, cells: cells, header: header, foldGap: foldGap)
    }

    /// Normalized cell centers (tour targets, calibration dots).
    var normalizedCenters: [CGPoint] {
        guard size.width > 0, size.height > 0 else { return [] }
        return cells.map { CGPoint(x: $0.midX / size.width, y: $0.midY / size.height) }
    }

    /// Skip-calibration mapping: a normalized point straight onto the grid.
    func zone(forNormalized p: CGPoint) -> Int? {
        guard size.width > 0, !cells.isEmpty else { return nil }
        let pt = CGPoint(x: p.x * size.width, y: p.y * size.height)
        if let hit = cells.firstIndex(where: { $0.contains(pt) }) { return hit }
        // In a gap or header: nearest cell center.
        return cells.indices.min { a, b in
            let ca = cells[a], cb = cells[b]
            return hypot(ca.midX - pt.x, ca.midY - pt.y) < hypot(cb.midX - pt.x, cb.midY - pt.y)
        }
    }
}
