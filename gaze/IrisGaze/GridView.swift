import SwiftUI

/// The 12 cells. Used by both the typing grid and calibration (with a LOOK HERE target).
struct GridView: View {
    let model: GazeModel
    let layout: GridLayout
    var calibrationTarget: Int? = nil

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let fold = layout.fold {
                FoldBand(rect: fold, simulated: layout.isSimulatedFold)
            }
            ForEach(GazeModel.cells) { cell in
                if let frame = layout.cells[safe: cell.id] {
                    let isTarget = calibrationTarget == cell.id
                    let isGazed = calibrationTarget == nil && model.zone == cell.id && !model.needsCalibration
                    CellView(
                        cell: cell,
                        isGazed: isGazed,
                        isTarget: isTarget,
                        progress: isTarget ? model.calibrationProgress : (isGazed ? model.dwellProgress : 0),
                        isFlashing: model.flashZone == cell.id,
                        isCalibrated: model.calibrator.medians[cell.id] != nil
                    )
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                    .onTapGesture(count: model.usingSimulated ? 2 : 1) { model.select(cell.id) }
                }
            }
        }
        .animation(.spring(duration: 0.3), value: calibrationTarget)
    }
}

struct FoldBand: View {
    let rect: CGRect
    let simulated: Bool

    var body: some View {
        ZStack {
            Rectangle().fill(.white.opacity(0.03))
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

struct CellView: View {
    let cell: GridCell
    let isGazed: Bool
    let isTarget: Bool
    let progress: Double
    let isFlashing: Bool
    let isCalibrated: Bool

    private var borderColor: Color {
        if isTarget { return Theme.look }
        if isGazed { return Theme.glow }
        return cell.kind == .suggest ? Theme.suggest.opacity(0.45) : Theme.cellBorder
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20)
        ZStack {
            shape.fill(isFlashing ? Theme.glow.opacity(0.55) : (isGazed ? Theme.glow.opacity(0.18) : Theme.cell.opacity(cell.kind == .suggest ? 0.6 : 1)))
            shape.strokeBorder(borderColor,
                               style: StrokeStyle(lineWidth: isGazed || isTarget ? 3 : 1.5,
                                                  dash: cell.kind == .suggest && !isGazed && !isTarget ? [7, 5] : []))
            if progress > 0 {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(isTarget ? Theme.look : Theme.glow, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .aspectRatio(1, contentMode: .fit)
                    .padding(10)
            }
            content
                .padding(.horizontal, 8)
                .padding(.top, 20)
                .padding(.bottom, 6)
            Text("\(cell.id)")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if isCalibrated && !isTarget {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green.opacity(0.7))
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .shadow(color: isGazed ? Theme.glow.opacity(0.7) : .clear, radius: 14)
        .shadow(color: isTarget ? Theme.look.opacity(0.6) : .clear, radius: 14)
        .animation(.easeOut(duration: 0.15), value: isGazed)
        .animation(.easeOut(duration: 0.2), value: isFlashing)
        .accessibilityElement()
        .accessibilityLabel(cell.caption.map { "\(cell.label), \($0)" } ?? cell.label)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 4) {
            Group {
                if let icon = cell.systemImage {
                    Image(systemName: icon)
                        .font(.system(size: 34, weight: .semibold))
                } else {
                    Text(cell.label)
                        .font(.system(size: cell.kind == .suggest ? 26 : 40, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.4)
                }
            }
            .foregroundStyle(cell.kind == .suggest ? Theme.suggest : Theme.text)
            if isTarget {
                Text("LOOK HERE")
                    .font(.caption2.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(Theme.look)
            } else if let caption = cell.caption {
                Text(caption)
                    .font(.caption2.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(Theme.muted)
            }
        }
    }
}
