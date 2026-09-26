import SwiftUI

struct CalibrationView: View {
    let model: GazeModel
    let layout: GridLayout

    var body: some View {
        ZStack(alignment: .topLeading) {
            GridView(model: model, layout: layout, calibrationTarget: model.calibratingZone)
                .opacity(model.isCalibrating ? 1 : 0.25)

            if !model.isCalibrating, let first = layout.cells.first, let last = layout.cells.last {
                CalibrationPrompt(model: model)
                    .frame(width: first.union(last).width, height: first.union(last).height)
                    .offset(x: first.minX, y: first.minY)
            }
        }
    }
}

struct CalibrationPrompt: View {
    let model: GazeModel

    var body: some View {
        VStack(spacing: 14) {
            Text("Calibrate")
                .font(.largeTitle.bold())
            Text("Look at each purple LOOK HERE cell until its ring fills. 12 cells, about 30 seconds. Keep your head still.")
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
