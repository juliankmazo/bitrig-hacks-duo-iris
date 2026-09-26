import SwiftUI

struct ContentView: View {
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @AppStorage("speechRate") private var speechRate = 0.5
  @State private var store = CommunicationStore()
  @State private var speech = SpeechService()
  @State private var showingPhrases = false
  @State private var showingSettings = false
  @State private var showingMessage = false
  @State private var showingEyeKeyboard = false

  var body: some View {
    NavigationStack {
      GeometryReader { geometry in
        if horizontalSizeClass == .regular && geometry.size.width >= 650 {
          HStack(alignment: .top, spacing: 20) {
            ScrollView {
              VStack(spacing: 16) {
                MessageCardView(
                  message: store.message,
                  isSpeaking: speech.isSpeaking,
                  onSpeak: speakMessage,
                  onStop: speech.stop,
                  onShow: { showingMessage = true },
                  onClear: { store.message = "" },
                  onEyeKeyboard: { showingEyeKeyboard = true }
                )
                ComposerView(store: store, speech: speech, rate: speechRate)
              }
              .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: 440)

            ScrollView {
              PhraseGridView(phrases: store.phrases) { phrase in
                store.message = phrase.text
                speech.speak(phrase.text, rate: speechRate)
              }
              .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
          }
          .padding(20)
        } else {
          ScrollView {
            VStack(spacing: 20) {
              MessageCardView(
                message: store.message,
                isSpeaking: speech.isSpeaking,
                onSpeak: speakMessage,
                onStop: speech.stop,
                onShow: { showingMessage = true },
                onClear: { store.message = "" },
                onEyeKeyboard: { showingEyeKeyboard = true }
              )
              PhraseGridView(phrases: store.phrases) { phrase in
                store.message = phrase.text
                speech.speak(phrase.text, rate: speechRate)
              }
            }
            .frame(maxWidth: .infinity)
            .padding(16)
          }
          .safeAreaInset(edge: .bottom, spacing: 0) {
            ComposerView(store: store, speech: speech, rate: speechRate)
              .padding(16)
              .frame(maxWidth: .infinity)
              .background(.regularMaterial)
          }
        }
      }
      .navigationTitle("Say It")
      .toolbar {
        ToolbarItemGroup(placement: .topBarTrailing) {
          Button("Edit phrases", systemImage: "square.and.pencil") {
            showingPhrases = true
          }
          Button("Settings", systemImage: "gearshape") {
            showingSettings = true
          }
        }
      }
      .sheet(isPresented: $showingPhrases) {
        PhraseManagerView(store: store)
      }
      .sheet(isPresented: $showingSettings) {
        SpeechSettingsView(speech: speech)
      }
      .fullScreenCover(isPresented: $showingMessage) {
        MessageDisplayView(message: store.message)
      }
      .fullScreenCover(isPresented: $showingEyeKeyboard) {
        EyeCommunicationView(store: store, speech: speech, rate: speechRate)
      }
    }
  }

  private func speakMessage() {
    speech.speak(store.message, rate: speechRate)
  }
}
