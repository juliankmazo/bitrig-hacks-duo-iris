import SwiftUI

struct ComposerView: View {
  @Bindable var store: CommunicationStore
  var speech: SpeechService
  var rate: Double
  @FocusState private var isFocused: Bool

  var body: some View {
    HStack(alignment: .bottom, spacing: 12) {
      TextField("Type a message", text: $store.message, axis: .vertical)
        .lineLimit(2...4)
        .font(.body)
        .textFieldStyle(.roundedBorder)
        .focused($isFocused)
        .submitLabel(.done)
        .accessibilityLabel("Message to speak")

      Button {
        isFocused = false
        speech.speak(store.message, rate: rate)
      } label: {
        Label("Speak", systemImage: "speaker.wave.2.fill")
          .frame(minHeight: 48)
      }
      .buttonStyle(.borderedProminent)
      .disabled(store.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .frame(maxWidth: .infinity)
  }
}
