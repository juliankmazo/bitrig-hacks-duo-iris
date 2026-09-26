import SwiftUI

struct EyeCommunicationView: View {
  @AppStorage("tapSimulationEnabled") private var tapSimulationEnabled = false
  var store: CommunicationStore
  var speech: SpeechService
  var rate: Double
  @State private var tracker = GazeTracker()

  var body: some View {
    if #available(iOS 27.1, *) {
      EyeBoardScreen(store: store, speech: speech, rate: rate, tracker: tracker, tapSimulationEnabled: $tapSimulationEnabled)
        .sceneAccessory {
          CameraCaptureAccessory {
            OutsideMessageView(message: store.message, rotatesForOuterDisplay: true)
              .onAppear { tracker.outerDisplayPresented = true }
              .onDisappear { tracker.outerDisplayPresented = false }
          }
          .onAvailabilityChange { available in
            tracker.outerDisplayAvailable = available
          }
        }
    } else {
      EyeBoardScreen(store: store, speech: speech, rate: rate, tracker: tracker, tapSimulationEnabled: $tapSimulationEnabled)
    }
  }
}
