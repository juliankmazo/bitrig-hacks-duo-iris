import SwiftUI

/// "Test" overlay: the live predicted gaze point, plus each calibration median projected through the fit
/// (orange dot) joined to its true cell center (white cross). Offsets that all point the same way are a
/// bias/scale problem; dots scattered around their crosses are noise.
struct DebugOverlay: View {
    let model: GazeModel
    let layout: GridLayout

    var body: some View {
        let size = layout.size
        let projected = model.calibrator.projected
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                for (p, t) in projected {
                    let a = CGPoint(x: t.x * size.width, y: t.y * size.height)
                    let b = CGPoint(x: p.x * size.width, y: p.y * size.height)
                    var line = Path()
                    line.move(to: a)
                    line.addLine(to: b)
                    ctx.stroke(line, with: .color(.orange.opacity(0.7)), lineWidth: 1.5)
                    var cross = Path()
                    cross.move(to: CGPoint(x: a.x - 7, y: a.y)); cross.addLine(to: CGPoint(x: a.x + 7, y: a.y))
                    cross.move(to: CGPoint(x: a.x, y: a.y - 7)); cross.addLine(to: CGPoint(x: a.x, y: a.y + 7))
                    ctx.stroke(cross, with: .color(Theme.text.opacity(0.7)), lineWidth: 1.5)
                    ctx.fill(Path(ellipseIn: CGRect(x: b.x - 5, y: b.y - 5, width: 10, height: 10)), with: .color(.orange))
                }
            }
            .allowsHitTesting(false)

            // Per-cell validation accuracy.
            ForEach(Array(model.validationPerCell.keys), id: \.self) { k in
                if let frame = layout.cells[safe: k], let acc = model.validationPerCell[k] {
                    Text("\(Int(acc * 100))%")
                        .font(.caption.monospacedDigit().bold())
                        .foregroundStyle(acc >= 0.8 ? .green : acc >= 0.5 ? .yellow : .red)
                        .padding(.horizontal, 5)
                        .background(.black.opacity(0.5), in: .capsule)
                        .position(x: frame.maxX - 24, y: frame.maxY - 14)
                }
            }

            if let name = model.recordingName, let last = layout.cells.last {
                Text("rec: Documents/\(name) · model \(model.calibrator.modelDescription) · implicit \(model.calibrator.implicitRows.count)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(Theme.muted)
                    .position(x: layout.size.width / 2, y: last.maxY + 10)
            }

            if let p = model.calibrator.smoothed {
                Circle()
                    .strokeBorder(.white, lineWidth: 2.5)
                    .background(Circle().fill(Theme.glow.opacity(0.35)))
                    .frame(width: 34, height: 34)
                    .position(x: p.x * size.width, y: p.y * size.height)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// Big, impossible-to-miss calibration target: a pulse, a countdown ring during settle,
/// a filling ring during sampling.
struct CalibrationTarget: View {
    let phase: GazeModel.CalibrationPhase?
    let progress: Double
    let cellSize: CGSize

    @State private var pulse = false

    var body: some View {
        let d = min(cellSize.width, cellSize.height) * 0.9
        ZStack {
            Circle()
                .stroke(Theme.look.opacity(pulse ? 0 : 0.8), lineWidth: 4)
                .frame(width: d, height: d)
                .scaleEffect(pulse ? 1.6 : 0.6)
            Circle()
                .stroke(.black.opacity(0.08), lineWidth: 7)
                .frame(width: d * 0.62, height: d * 0.62)
            Circle()
                .trim(from: 0, to: phase == .settle ? 1 - progress : progress)
                .stroke(phase == .sampling ? Color.green : phase == .moving ? Color.orange
                            : phase == .validating ? Theme.glow : Theme.look,
                        style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: d * 0.62, height: d * 0.62)
            Circle().fill(Theme.look).frame(width: 16, height: 16)
            Circle().fill(.white).frame(width: 6, height: 6)
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 28))
                .foregroundStyle(Theme.look)
                .offset(y: -d * 0.62 / 2 - 22 + (pulse ? -6 : 0))
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeOut(duration: 1.0).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}
