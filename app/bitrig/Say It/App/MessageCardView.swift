import SwiftUI

struct MessageCardView: View {
  var message: String
  var isSpeaking: Bool
  var onSpeak: () -> Void
  var onStop: () -> Void
  var onShow: () -> Void
  var onClear: () -> Void
  var onEyeKeyboard: () -> Void

  private var hasMessage: Bool {
    !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Label("Your message", systemImage: "text.bubble.fill")
          .font(.headline)
        Spacer()
        if hasMessage {
          Button("Clear message", systemImage: "xmark", action: onClear)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        }
      }

      Text(hasMessage ? message : "Choose a phrase or type a message below.")
        .font(hasMessage ? .title2.weight(.semibold) : .body)
        .foregroundStyle(hasMessage ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)

      HStack(spacing: 12) {
        Button(isSpeaking ? "Stop" : "Speak again", systemImage: isSpeaking ? "speaker.slash.fill" : "speaker.wave.2.fill") {
          if isSpeaking { onStop() } else { onSpeak() }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!hasMessage)

        Button("Show here", systemImage: "rectangle.expand.vertical", action: onShow)
          .buttonStyle(.bordered)
          .controlSize(.large)
          .disabled(!hasMessage)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Button("Open eye keyboard", systemImage: "eye", action: onEyeKeyboard)
        .buttonStyle(.bordered)
        .controlSize(.large)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
  }
}
