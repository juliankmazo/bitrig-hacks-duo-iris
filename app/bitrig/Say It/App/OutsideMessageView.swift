import SwiftUI

struct OutsideMessageView: View {
  var message: String
  var rotatesForOuterDisplay = false

  var body: some View {
    GeometryReader { geometry in
      if rotatesForOuterDisplay {
        OutsideMessageCanvas(message: message, size: CGSize(width: geometry.size.height, height: geometry.size.width))
          .frame(width: geometry.size.height, height: geometry.size.width)
          .rotationEffect(.degrees(-90))
          .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
      } else {
        OutsideMessageCanvas(message: message, size: geometry.size)
          .frame(width: geometry.size.width, height: geometry.size.height)
      }
    }
    .background(Color.black.ignoresSafeArea())
  }
}

private struct OutsideMessageCanvas: View {
  @ScaledMetric(relativeTo: .largeTitle) private var messageSize = 52
  var message: String
  var size: CGSize

  var body: some View {
    let isLandscape = size.width > size.height
    let horizontalPadding: CGFloat = isLandscape ? 48 : 28
    let verticalPadding: CGFloat = isLandscape ? 20 : 28

    ScrollView {
      Text(message.isEmpty ? "Ready to listen" : message)
        .font(.system(size: messageSize, weight: .bold, design: .rounded))
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .padding(.horizontal, horizontalPadding)
        .frame(
          maxWidth: .infinity,
          minHeight: max(0, size.height - verticalPadding * 2)
        )
        .padding(.vertical, verticalPadding)
    }
  }
}
