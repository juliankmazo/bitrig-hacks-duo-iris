import SwiftUI

struct PhraseEditorView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var text: String
  var phrase: QuickPhrase?
  var onSave: (String) -> Void
  var onDelete: () -> Void

  init(phrase: QuickPhrase?, onSave: @escaping (String) -> Void, onDelete: @escaping () -> Void) {
    self.phrase = phrase
    self.onSave = onSave
    self.onDelete = onDelete
    _text = State(initialValue: phrase?.text ?? "")
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Phrase") {
          TextField("What would you like to say?", text: $text, axis: .vertical)
            .lineLimit(2...5)
            .accessibilityLabel("Phrase text")
        }

        if phrase != nil {
          Section {
            Button("Delete phrase", role: .destructive) {
              onDelete()
              dismiss()
            }
          }
        }
      }
      .navigationTitle(phrase == nil ? "Add phrase" : "Edit phrase")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", role: .cancel) { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            onSave(text.trimmingCharacters(in: .whitespacesAndNewlines))
            dismiss()
          }
          .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
    }
  }
}
