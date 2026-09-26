import Foundation
import Observation

@MainActor
@Observable
final class CommunicationStore {
  var message: String {
    didSet { UserDefaults.standard.set(message, forKey: Self.messageKey) }
  }

  var phrases: [QuickPhrase] {
    didSet { savePhrases() }
  }

  private static let messageKey = "currentMessage"
  private static let phrasesKey = "quickPhrases"

  init() {
    message = UserDefaults.standard.string(forKey: Self.messageKey) ?? ""
    if let data = UserDefaults.standard.data(forKey: Self.phrasesKey),
       let saved = try? JSONDecoder().decode([QuickPhrase].self, from: data) {
      phrases = saved
    } else {
      phrases = [
        QuickPhrase(text: "Yes"),
        QuickPhrase(text: "No"),
        QuickPhrase(text: "Please give me a moment"),
        QuickPhrase(text: "I need help"),
        QuickPhrase(text: "I'm uncomfortable"),
        QuickPhrase(text: "Can you reposition me?"),
        QuickPhrase(text: "I'm in pain"),
        QuickPhrase(text: "Thank you")
      ]
    }
  }

  func addPhrase(_ text: String) {
    phrases.append(QuickPhrase(text: text))
  }

  func updatePhrase(_ phrase: QuickPhrase, text: String) {
    guard let index = phrases.firstIndex(where: { $0.id == phrase.id }) else { return }
    phrases[index].text = text
  }

  func deletePhrase(_ phrase: QuickPhrase) {
    phrases.removeAll { $0.id == phrase.id }
  }

  func deletePhrases(at offsets: IndexSet) {
    phrases.remove(atOffsets: offsets)
  }

  private func savePhrases() {
    guard let data = try? JSONEncoder().encode(phrases) else { return }
    UserDefaults.standard.set(data, forKey: Self.phrasesKey)
  }
}
