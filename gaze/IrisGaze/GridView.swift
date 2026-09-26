import SwiftUI

/// The 12 cells. Used by both the typing keyboard and calibration (with a LOOK HERE target).
struct GridView: View {
    let model: GazeModel
    let layout: GridLayout
    var calibrationTarget: Int? = nil
    /// Typing (not calibration): level 2 and live suggestions apply.
    var isTyping = true

    private var isKeyboard: Bool { isTyping && calibrationTarget == nil }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let fold = layout.fold {
                FoldBand(rect: fold, simulated: layout.isSimulatedFold)
            }
            // Very faint row / column feedback: nodding picks the row, the eyes pick the column.
            if model.chrome, calibrationTarget == nil, !model.needsCalibration, let z = model.zone, layout.cells.count == 12 {
                let row = (0..<4).map { layout.cells[(z / 4) * 4 + $0] }.reduce(CGRect.null) { $0.union($1) }
                let col = (0..<3).map { layout.cells[$0 * 4 + z % 4] }.reduce(CGRect.null) { $0.union($1) }
                RoundedRectangle(cornerRadius: 34)
                    .fill(Theme.glow.opacity(0.05))
                    .frame(width: row.width + 14, height: row.height + 14)
                    .offset(x: row.minX - 7, y: row.minY - 7)
                RoundedRectangle(cornerRadius: 34)
                    .fill(Theme.glow.opacity(0.05))
                    .frame(width: col.width + 14, height: col.height + 14)
                    .offset(x: col.minX - 7, y: col.minY - 7)
            }
            Group {
                if isKeyboard, let g = model.level2Group {
                    level2(group: g)
                } else {
                    level1
                }
            }
            .id(isKeyboard ? (model.level2Group ?? -1) : -1)
            .transition(.scale(scale: 0.2, anchor: zoomAnchor).combined(with: .opacity))
        }
        .animation(.spring(duration: 0.3), value: calibrationTarget)
    }

    private var zoomAnchor: UnitPoint {
        guard let f = layout.cells[safe: model.zoomOrigin], layout.size.width > 0 else { return .center }
        return UnitPoint(x: f.midX / layout.size.width, y: f.midY / layout.size.height)
    }

    private var level1: some View {
        let suggestions = model.suggestions
        return ForEach(GazeModel.cells) { base in
            if let frame = layout.cells[safe: base.id] {
                let cell = isKeyboard && base.kind == .suggest
                    ? GridCell(id: base.id, label: suggestions[safe: [3: 0, 7: 1, 11: 2][base.id] ?? 0] ?? base.label, kind: .suggest)
                    : base
                let isTarget = calibrationTarget == cell.id
                let isGazed = calibrationTarget == nil && model.zone == cell.id && !model.needsCalibration
                CellView(
                    cell: cell,
                    isGazed: isGazed,
                    isTarget: isTarget,
                    progress: isTarget ? model.calibrationProgress : (isGazed ? model.dwellProgress : 0),
                    isFlashing: model.flashZone == cell.id,
                    isCalibrated: !isTyping && model.calibrator.calibratedCells.contains(cell.id)
                )
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
                .onTapGesture(count: model.usingSimulated ? 2 : 1) { model.select(cell.id) }
            }
        }
    }

    /// Level 2: the group's items (row 0: first 4, row 1: the rest), "← back" across the bottom row.
    private func level2(group: Int) -> some View {
        ForEach(Keyboard.keys(forGroup: group)) { key in
            let frame = key.cells.compactMap { layout.cells[safe: $0] }.reduce(CGRect.null) { $0.union($1) }
            let isGazed = model.zone.map { key.cells.contains($0) } ?? false
            CellView(
                cell: GridCell(id: key.cells[0], label: key.label, kind: key.isBack ? .back : .letters),
                isGazed: isGazed && !model.needsCalibration,
                isTarget: false,
                progress: isGazed ? model.dwellProgress : 0,
                isFlashing: model.flashZone.map { key.cells.contains($0) } ?? false,
                isCalibrated: false,
                large: !key.isBack
            )
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
            .onTapGesture(count: model.usingSimulated ? 2 : 1) { model.select(key.cells[0]) }
        }
    }
}

struct FoldBand: View {
    let rect: CGRect
    let simulated: Bool

    var body: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.03))
            Text(simulated ? "fold (simulated)" : "fold")
                .font(.caption2.smallCaps())
                .foregroundStyle(Theme.muted.opacity(0.6))
                .rotationEffect(rect.height > rect.width ? .degrees(-90) : .zero)
                .fixedSize()
        }
        .frame(width: rect.width, height: rect.height)
        .offset(x: rect.minX, y: rect.minY)
        .allowsHitTesting(false)
    }
}

/// One key, light theme: off-white letter cells with a soft shadow, near-black action cells,
/// soft-blue word cells. Gaze: 4 pt blue outline + blue progress ring.
struct CellView: View {
    let cell: GridCell
    let isGazed: Bool
    let isTarget: Bool
    let progress: Double
    let isFlashing: Bool
    let isCalibrated: Bool
    var large = false

    private var isDark: Bool { [.delete, .space, .startOver, .back].contains(cell.kind) }

    private var fill: Color {
        if isFlashing { return Theme.glow.opacity(0.35) }
        switch cell.kind {
        case .suggest: return Theme.suggestFill
        case .delete, .space, .startOver, .back: return Theme.action
        case .letters: return Theme.cell
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        ZStack {
            shape.fill(fill)
                .shadow(color: .black.opacity(0.10), radius: 10, y: 4)
            if isGazed || isTarget {
                shape.strokeBorder(isTarget ? Theme.look : Theme.glow, lineWidth: 4)
            }
            if progress > 0 {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(isTarget ? Theme.look : Theme.glow, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .aspectRatio(1, contentMode: .fit)
                    .padding(14)
                    .opacity(0.9)
            }
            VStack(spacing: 6) {
                Text(cell.label)
                    .font(.system(size: large ? 96 : 34, weight: .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                if let sub = cell.sub {
                    Text(sub)
                        .font(.system(size: 34, weight: .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.4)
                }
                if isTarget {
                    Text("LOOK HERE")
                        .font(.caption.weight(.bold))
                        .tracking(1.2)
                        .foregroundStyle(Theme.look)
                }
            }
            .foregroundStyle(isDark ? .white : Theme.text)
            .padding(12)
            if isCalibrated && !isTarget {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .animation(.easeOut(duration: 0.15), value: isGazed)
        .animation(.easeOut(duration: 0.2), value: isFlashing)
        .accessibilityElement()
        .accessibilityLabel(cell.sub.map { "\(cell.label), \($0)" } ?? cell.label)
        .accessibilityAddTraits(.isButton)
    }
}
