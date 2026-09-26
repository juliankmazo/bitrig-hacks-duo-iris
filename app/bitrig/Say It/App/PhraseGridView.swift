import SwiftUI

struct PhraseGridView: View {
  var phrases: [QuickPhrase]
  var onSelect: (QuickPhrase) -> Void

  private var columns: [GridItem] {
    [GridItem(.adaptive(minimum: 150, maximum: 260), spacing: 12, alignment: .top)]
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Quick phrases")
          .font(.title2.bold())
        Text("Tap a phrase to say it aloud.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      if phrases.isEmpty {
        ContentUnavailableView("No quick phrases", systemImage: "text.bubble", description: Text("Add phrases with the Edit phrases button."))
      } else {
        LazyVGrid(columns: columns, spacing: 12) {
          ForEach(phrases) { phrase in
            Button {
              onSelect(phrase)
            } label: {
              VStack(alignment: .leading, spacing: 12) {
                Text(phrase.text)
                  .font(.headline)
                  .multilineTextAlignment(.leading)
                  .foregroundStyle(.primary)
                  .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "speaker.wave.2.fill")
                  .font(.subheadline)
                  .foregroundStyle(.tint)
              }
              .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
              .padding(16)
              .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Say \(phrase.text)")
            .accessibilityHint("Speaks this phrase and puts it in your message")
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
