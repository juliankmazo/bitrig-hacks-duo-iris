import SwiftUI

struct CalibrationView: View {
    let model: GazeModel
    let layout: GridLayout

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.isCalibrating ? Array(layout.cells.indices) : [], id: \.self) { i in
                let frame = layout.cells[i]
                let done = model.calibrator.centroids[i] != nil
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(done ? Color.green.opacity(0.5) : Color.white.opacity(0.12), lineWidth: 1)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
            }

            if let k = model.calibratingZone, let frame = layout.cells[safe: k] {
                CalibrationDot(progress: model.calibrationProgress)
                    .position(x: frame.midX, y: frame.midY)
                    .id(k)
                    .transition(.scale)
            }

            if !model.isCalibrating, let first = layout.cells.first, let last = layout.cells.last {
                let area = first.union(last)
                VStack(spacing: 20) {
                    Text("Calibrate")
                        .font(.largeTitle.bold())
                    Text("Look at each dot until its ring fills. 12 dots, about 25 seconds.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 16) {
                        Button("Start", systemImage: "eye") { model.startCalibration() }
                            .buttonStyle(.borderedProminent)
                        Button("Skip", systemImage: "forward") { model.skipCalibration() }
                            .buttonStyle(.bordered)
                    }
                    .controlSize(.large)
                    Text("Calibrated \(model.calibrator.calibratedCount)/12")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(32)
                .frame(width: area.width, height: area.height)
                .offset(x: area.minX, y: area.minY)
            }
        }
        .animation(.spring(duration: 0.35), value: model.calibratingZone)
    }
}

struct CalibrationDot: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle().fill(.orange).frame(width: 22, height: 22)
            Circle()
                .stroke(.white.opacity(0.15), lineWidth: 6)
                .frame(width: 70, height: 70)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(.orange, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 70, height: 70)
        }
    }
}
