import SwiftUI

/// Shown when the device is closed.
struct IdleView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "eye")
                .font(.system(size: 64, weight: .light))
            Text("Iris")
                .font(.system(size: 96, weight: .bold, design: .rounded))
            Text("Open to talk")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
