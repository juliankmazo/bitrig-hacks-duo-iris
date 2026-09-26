import SwiftUI

struct CalibrationView: View {
    let model: GazeModel
    let layout: GridLayout

    var body: some View {
        ZStack(alignment: .topLeading) {
            GridView(model: model, layout: layout, calibrationTarget: model.calibratingZone, isTyping: false)
                .opacity(model.isCalibrating ? 0.55 : 0.25)

            if model.isCalibrating, model.calibrationStep > 0 {
                Text("\(model.calibrationStep) / \(model.calibrationTotal)")
                    .font(.system(size: 17, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.muted)
                    .position(x: layout.size.width / 2, y: max(layout.panel.midY, 60))
            }

            if let t = model.calibrationTarget, let cellSize = layout.cells.first?.size {
                let p = CGPoint(x: t.x * layout.size.width, y: t.y * layout.size.height)
                CalibrationTarget(phase: model.calibrationPhase, progress: model.calibrationProgress, cellSize: cellSize)
                    .position(p)
                    .id("\(t.x),\(t.y)")
                if let text = model.calibrationInstruction {
                    Text(text)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Theme.look.opacity(0.85), in: .capsule)
                        .fixedSize()
                        .position(x: min(max(p.x, 170), layout.size.width - 170),
                                  y: p.y + cellSize.height * 0.45 > (layout.cells.last?.maxY ?? 0)
                                    ? p.y - cellSize.height * 0.5 : p.y + cellSize.height * 0.5)
                        .allowsHitTesting(false)
                }
            }

            if let first = layout.cells.first, let last = layout.cells.last {
                let area = first.union(last)
                if !model.isCalibrating {
                    CalibrationPrompt(model: model)
                        .frame(width: area.width, height: area.height)
                        .offset(x: area.minX, y: area.minY)
                } else if let message = model.calibrationMessage {
                    Text(message)
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Color.red.opacity(0.75), in: .capsule)
                        .position(x: area.midX, y: area.maxY - 24)
                }
            }
        }
        .animation(.spring(duration: 0.3), value: model.calibratingZone)
    }
}

struct CalibrationPrompt: View {
    let model: GazeModel

    var body: some View {
        VStack(spacing: 14) {
            Text("Calibrate")
                .font(.largeTitle.bold())
            Text("Look at the purple target in each cell. Hold still while the ring counts down, keep looking while it fills green. 12 cells, about 35 seconds.")
                .font(.title3)
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
            HStack(spacing: 16) {
                Button("Start", systemImage: "eye") { model.startCalibration() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.look)
                Button("Skip", systemImage: "forward") { model.skipCalibration() }
                    .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
        .foregroundStyle(Theme.text)
        .padding(24)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
