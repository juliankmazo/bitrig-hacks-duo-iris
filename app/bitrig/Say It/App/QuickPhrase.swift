import Foundation

struct QuickPhrase: Codable, Equatable, Identifiable {
  var id: UUID
  var text: String

  init(id: UUID = UUID(), text: String) {
    self.id = id
    self.text = text
  }
}
