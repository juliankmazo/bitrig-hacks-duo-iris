import SwiftUI

struct EyeBoardScreen: View {
  @Environment(\.dismiss) private var dismiss
  var store: CommunicationStore
  var speech: SpeechService
  var rate: Double
  var tracker: GazeTracker
  @Binding var tapSimulationEnabled: Bool

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        Toggle("Simulate with taps", isOn: $tapSimulationEnabled)
          .accessibilityHint("Selects keyboard keys by tap instead of gaze")
          .padding(.horizontal, 20)
          .padding(.vertical, 12)
        Divider()

        if tapSimulationEnabled {
          TapSimulationControls(tracker: tracker)
          EyeKeyboardSurface(
            store: store,
            speech: speech,
            rate: rate,
            tracker: tracker,
            isTapSimulation: true
          )
        } else {
          Group {
            switch tracker.phase {
            case .inactive:
              ContentUnavailableView {
                Label("Eye keyboard", systemImage: "eye")
              } description: {
                Text("Look at each key to select it. The front camera stays on while eye control is active. Camera images stay on this iPhone and are not saved.")
              } actions: {
                Button("Start eye control", systemImage: "camera.fill") {
                  Task { await tracker.start() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
              }
            case .starting, .projectionOnly:
              ProgressView("Starting eye control…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .calibrating:
              GazeCalibrationView(tracker: tracker)
            case .ready:
              EyeKeyboardSurface(
                store: store,
                speech: speech,
                rate: rate,
                tracker: tracker,
                isTapSimulation: false
              )
            case .failed(let reason):
              VStack(spacing: 20) {
                ContentUnavailableView("Eye control unavailable", systemImage: "eye.slash", description: Text(reason))
                Button("Try again") {
                  tracker.stop()
                  Task { await tracker.start() }
                }
                .buttonStyle(.borderedProminent)
                Text("You can still type and use quick phrases on the main screen.")
                  .font(.subheadline)
                  .foregroundStyle(.secondary)
              }
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .padding()
            }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .navigationTitle("Eye keyboard")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
        if !tapSimulationEnabled && tracker.phase == .ready {
          ToolbarItem(placement: .topBarTrailing) {
            Button("Recalibrate", systemImage: "scope") { tracker.resetCalibration() }
          }
        }
      }
      .onGeometryChange(for: Bool.self) { geometry in
        geometry.size.width > geometry.size.height
      } action: { isLandscape in
        tracker.setLandscape(isLandscape)
      }
      .onChange(of: tapSimulationEnabled) { _, isEnabled in
        if isEnabled {
          tracker.enterTapSimulation()
        } else {
          tracker.leaveTapSimulation()
        }
      }
      .onDisappear { tracker.stop() }
    }
  }
}

private struct TapSimulationControls: View {
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  var tracker: GazeTracker

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        if #available(iOS 27.1, *), horizontalSizeClass == .regular {
          switch tracker.phase {
          case .inactive, .failed:
            Button("Show message outside", systemImage: "camera.fill") {
              tracker.stop()
              Task { await tracker.startProjection() }
            }
            .buttonStyle(.bordered)
          case .starting:
            ProgressView("Starting camera…")
          case .calibrating, .ready, .projectionOnly:
            Button("Stop outside display", systemImage: "camera.fill") { tracker.stop() }
              .buttonStyle(.bordered)
          }
        } else {
          Text("Tap mode works without the camera.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      if case .failed(let reason) = tracker.phase {
        Text(reason)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 16)
    .padding(.top, 12)
  }
}
