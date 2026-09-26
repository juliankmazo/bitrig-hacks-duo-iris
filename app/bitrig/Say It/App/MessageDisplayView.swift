import SwiftUI

struct MessageDisplayView: View {
  @Environment(\.dismiss) private var dismiss
  var message: String

  var body: some View {
    OutsideMessageView(message: message)
      .safeAreaInset(edge: .top) {
        HStack {
          Spacer()
          Button("Done", systemImage: "xmark") { dismiss() }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .foregroundStyle(.black)
        }
        .padding()
      }
  }
}
