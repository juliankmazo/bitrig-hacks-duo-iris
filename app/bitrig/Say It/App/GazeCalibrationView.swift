import SwiftUI

struct GazeCalibrationView: View {
  var tracker: GazeTracker

  private let targets: [CGPoint] = [
    CGPoint(x: 0.16, y: 0.18),
    CGPoint(x: 0.84, y: 0.18),
    CGPoint(x: 0.50, y: 0.50),
    CGPoint(x: 0.16, y: 0.82),
    CGPoint(x: 0.84, y: 0.82)
  ]

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        Color(uiColor: .systemBackground)

        VStack(spacing: 8) {
          Text("Follow the dot with your eyes")
            .font(.title2.bold())
          Text("Hold your gaze for about two seconds. Keep the phone steady and your face in view.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
          Label(
            tracker.faceVisible ? "Eyes found" : "Looking for your eyes…",
            systemImage: tracker.faceVisible ? "checkmark.circle.fill" : "eye"
          )
          .font(.subheadline)
          .foregroundStyle(tracker.faceVisible ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
          Text("\(min(tracker.calibrationStep + 1, 5)) of 5")
            .font(.headline)
            .padding(.top, 8)
          Spacer()
          Button("Cancel eye control") { tracker.stop() }
            .buttonStyle(.bordered)
        }
        .padding(20)

        if tracker.calibrationStep < targets.count {
          Circle()
            .fill(.tint)
            .frame(width: 38, height: 38)
            .overlay {
              Circle().strokeBorder(.white, lineWidth: 4).padding(5)
            }
            .position(
              x: geometry.size.width * targets[tracker.calibrationStep].x,
              y: geometry.size.height * targets[tracker.calibrationStep].y
            )
            .accessibilityHidden(true)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .task(id: tracker.calibrationStep) {
      let step = tracker.calibrationStep
      while !Task.isCancelled && tracker.phase == .calibrating && tracker.calibrationStep == step {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        guard !Task.isCancelled else { return }
        if tracker.captureCalibrationPoint() { return }
      }
    }
  }
}
