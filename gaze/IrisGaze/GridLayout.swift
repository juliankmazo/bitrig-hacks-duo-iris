import CoreGraphics
import SwiftUI

/// Pose used when the system reports no active division (flat, or the simulator).
enum SimulatedPose: String {
    case laptop, book, flat

    /// `-pose laptop|book|flat`. `flat` forces the flat layout even when a fold region is active
    /// (Julian holds the phone fully open); otherwise real fold regions win and this only fills in.
    static let forced = UserDefaults.standard.string(forKey: "pose").flatMap(SimulatedPose.init(rawValue:))
    static let launchValue = forced ?? .flat
}

/// Fold-aware 4x3 grid geometry. Recomputed on every layout pass from the live
/// reserved regions (never cached: they are empty on the first pass).
///
/// - Horizontal fold (laptop): grid in the upright TOP region, panel on the flat BOTTOM region.
/// - Vertical fold (book): panel on top, grid below with 2 columns per side and a wide crease gap.
/// - No active division: falls back to `SimulatedPose` so the simulator matches the demo.
struct GridLayout: Equatable {
    static let columns = 4
    static let rows = 3

    enum Arrangement: String { case laptop, book, flat }

    var size: CGSize
    var cells: [CGRect]
    /// The status/selection panel (bottom region in laptop pose, a top strip otherwise).
    var panel: CGRect
    /// The crease the grid avoids (real division frame, or the simulated one).
    var fold: CGRect?
    var arrangement: Arrangement
    var isSimulatedFold: Bool

    static func make(size: CGSize,
                     divisions: [ReservedRegion],
                     occlusions: [ReservedRegion],
                     simulatedPose: SimulatedPose) -> GridLayout {
        let outer: CGFloat = 16
        let gap: CGFloat = 12
        let headerHeight: CGFloat = 175

        // Inset for occlusions (cameras): give up a strip of height unless the region is a tall side strip.
        var top = outer, bottom = outer, left = outer, right = outer
        for r in occlusions where r.isActive {
            let f = r.frame, m = r.margins
            if f.height <= size.height / 3 {
                if f.minY <= size.height - f.maxY { top = max(top, f.maxY + m.bottom) }
                else { bottom = max(bottom, size.height - f.minY + m.top) }
            } else if f.minX <= size.width - f.maxX {
                left = max(left, f.maxX + m.trailing)
            } else {
                right = max(right, size.width - f.minX + m.leading)
            }
        }
        let content = CGRect(x: left, y: top,
                             width: max(0, size.width - left - right),
                             height: max(0, size.height - top - bottom))

        // Real division first; otherwise simulate one for the chosen pose.
        var arrangement: Arrangement
        var fold: CGRect?
        var foldMargins = EdgeInsets(top: gap, leading: gap, bottom: gap, trailing: gap)
        var simulated = false
        if SimulatedPose.forced != .flat,
           let d = divisions.first(where: { $0.isActive && ($0.frame.width > 0 || $0.frame.height > 0) }) {
            fold = d.frame
            foldMargins = d.margins
            arrangement = d.frame.width > d.frame.height ? .laptop : .book
        } else {
            simulated = true
            switch simulatedPose {
            case .laptop:
                arrangement = .laptop
                fold = CGRect(x: 0, y: content.midY - 14, width: size.width, height: 28)
            case .book:
                arrangement = .book
                fold = CGRect(x: content.midX - 14, y: 0, width: 28, height: size.height)
            case .flat:
                arrangement = .flat
            }
        }

        var gridRect: CGRect
        var panel: CGRect
        switch arrangement {
        case .laptop:
            let f = fold!
            let gridBottom = max(content.minY, f.minY - max(foldMargins.top, gap))
            let panelTop = min(content.maxY, f.maxY + max(foldMargins.bottom, gap))
            gridRect = CGRect(x: content.minX, y: content.minY, width: content.width, height: gridBottom - content.minY)
            panel = CGRect(x: content.minX, y: panelTop, width: content.width, height: content.maxY - panelTop)
        case .flat:
            // Flat 180°: top 25 % = typed text + status, bottom 75 % = keyboard.
            let h = (content.height * 0.25).rounded()
            panel = CGRect(x: content.minX, y: content.minY, width: content.width, height: h)
            let y = content.minY + h + gap
            gridRect = CGRect(x: content.minX, y: y, width: content.width, height: max(0, content.maxY - y))
        case .book:
            panel = CGRect(x: content.minX, y: content.minY, width: content.width, height: headerHeight)
            let y = content.minY + headerHeight + gap
            gridRect = CGRect(x: content.minX, y: y, width: content.width, height: max(0, content.maxY - y))
        }

        // Keyboard design: gap ≈ 1/6 of a cell width (4 cells + 3 gaps = 4.5 cell widths).
        let cellGap = max(gap, (gridRect.width / 4.5 / 6).rounded())
        // Columns: split 2 + 2 around a vertical fold, else even.
        var xs: [(CGFloat, CGFloat)]
        if arrangement == .book, let f = fold, f.midX > gridRect.minX, f.midX < gridRect.maxX {
            let leftEnd = f.minX - max(foldMargins.leading, cellGap / 2)
            let rightStart = f.maxX + max(foldMargins.trailing, cellGap / 2)
            let lw = max(0, (leftEnd - gridRect.minX - cellGap) / 2)
            let rw = max(0, (gridRect.maxX - rightStart - cellGap) / 2)
            xs = [(gridRect.minX, lw), (gridRect.minX + lw + cellGap, lw),
                  (rightStart, rw), (rightStart + rw + cellGap, rw)]
        } else {
            let cw = max(0, (gridRect.width - cellGap * CGFloat(columns - 1)) / CGFloat(columns))
            xs = (0..<columns).map { (gridRect.minX + CGFloat($0) * (cw + cellGap), cw) }
        }
        let rowH = max(0, (gridRect.height - cellGap * CGFloat(rows - 1)) / CGFloat(rows))
        var cells: [CGRect] = []
        for r in 0..<rows {
            for c in 0..<columns {
                cells.append(CGRect(x: xs[c].0, y: gridRect.minY + CGFloat(r) * (rowH + cellGap),
                                    width: xs[c].1, height: rowH))
            }
        }
        return GridLayout(size: size, cells: cells, panel: panel, fold: fold,
                          arrangement: arrangement, isSimulatedFold: simulated)
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
        return cells.indices.min { a, b in
            let ca = cells[a], cb = cells[b]
            return hypot(ca.midX - pt.x, ca.midY - pt.y) < hypot(cb.midX - pt.x, cb.midY - pt.y)
        }
    }
}
