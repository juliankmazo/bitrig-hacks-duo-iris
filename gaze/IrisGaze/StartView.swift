import SwiftUI

/// Demo start screen: the name, one big Calibrate button, one line of instruction. Nothing else.
struct StartView: View {
    let model: GazeModel

    var body: some View {
        ZStack {
            Color.white
            VStack {
                Text("Iris")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                    .padding(.top, 70)
                Spacer()
            }
            VStack(spacing: 22) {
                HStack(spacing: 16) {
                    Button { model.beginCalibration() } label: {
                        Text("Calibrate")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 56)
                            .padding(.vertical, 22)
                            .background(Theme.speaker, in: .capsule)
                    }
                    .buttonStyle(.plain)
                    if model.savedCalibrationAvailable {
                        Button { model.useLastCalibration() } label: {
                            Text("Use last calibration")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(Theme.speaker)
                                .padding(.horizontal, 22)
                                .padding(.vertical, 14)
                                .background(Theme.speaker.opacity(0.10), in: .capsule)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text("Look at each target and point your nose at it")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.muted)
            }
            // Tiny face-status dot.
            Circle()
                .fill(model.source.sample.faceDetected ? Color.green : Color.gray.opacity(0.4))
                .frame(width: 10, height: 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(24)
        }
    }
}
