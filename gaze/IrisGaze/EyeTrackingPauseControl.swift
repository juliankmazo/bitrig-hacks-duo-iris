import SwiftUI

struct EyeTrackingPauseControl: View {
    let model: GazeModel

    var body: some View {
        Button {
            model.setEyeTrackingPaused(!model.isEyeTrackingPaused)
        } label: {
            Label(
                model.isEyeTrackingPaused ? "Resume" : "Pause",
                systemImage: model.isEyeTrackingPaused ? "play.fill" : "pause.fill"
            )
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(model.isEyeTrackingPaused ? .white : Theme.text)
            .padding(.horizontal, 18)
            .frame(height: 58)
            .background(model.isEyeTrackingPaused ? Theme.look : Theme.cell, in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.isEyeTrackingPaused ? "Resume eye tracking" : "Pause eye tracking")
        .accessibilityHint("Stops gaze selections while touch controls remain available")
        .sensoryFeedback(.selection, trigger: model.isEyeTrackingPaused)
    }
}
