import SwiftUI

struct SpeechSettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @AppStorage("speechRate") private var speechRate = 0.5
  @AppStorage("gazeDwellTime") private var gazeDwellTime = 1.2
  var speech: SpeechService

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Slider(value: $speechRate, in: 0.35...0.65) {
            Text("Speaking speed")
          } minimumValueLabel: {
            Text("Slow")
          } maximumValueLabel: {
            Text("Fast")
          }
          Button("Hear a sample", systemImage: "speaker.wave.2.fill") {
            speech.speak("This is how I sound.", rate: speechRate)
          }
        } header: {
          Text("Voice")
        } footer: {
          Text("Speech uses the iPhone's voice for your language. The speed applies to every phrase and message.")
        }

        Section("Eye control") {
          Slider(value: $gazeDwellTime, in: 0.8...2.5) {
            Text("Time to select a key")
          } minimumValueLabel: {
            Text("Short")
          } maximumValueLabel: {
            Text("Long")
          }
        }
      }
      .navigationTitle("Settings")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
  }
}
