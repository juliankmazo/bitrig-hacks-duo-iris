import SwiftUI

struct PhraseManagerView: View {
  @Environment(\.dismiss) private var dismiss
  var store: CommunicationStore
  @State private var editor: PhraseEditor?

  var body: some View {
    NavigationStack {
      List {
        Section {
          ForEach(store.phrases) { phrase in
            Button {
              editor = .edit(phrase)
            } label: {
              Text(phrase.text)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            }
          }
          .onDelete(perform: store.deletePhrases)
        } footer: {
          Text("Tap a phrase to edit it. Your changes are saved on this iPhone.")
        }
      }
      .navigationTitle("Quick phrases")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Done") { dismiss() }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button("Add phrase", systemImage: "plus") { editor = .add }
        }
      }
      .sheet(item: $editor) { choice in
        PhraseEditorView(phrase: choice.phrase) { text in
          switch choice {
          case .add:
            store.addPhrase(text)
          case .edit(let phrase):
            store.updatePhrase(phrase, text: text)
          }
        } onDelete: {
          if case .edit(let phrase) = choice {
            store.deletePhrase(phrase)
          }
        }
      }
    }
  }
}

private enum PhraseEditor: Identifiable {
  case add
  case edit(QuickPhrase)

  var id: String {
    switch self {
    case .add: "add"
    case .edit(let phrase): phrase.id.uuidString
    }
  }

  var phrase: QuickPhrase? {
    if case .edit(let phrase) = self { return phrase }
    return nil
  }
}
