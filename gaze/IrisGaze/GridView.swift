import SwiftUI

struct GridView: View {
    let model: GazeModel
    let layout: GridLayout

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let gap = layout.foldGap {
                // Visualize the crease the grid is avoiding.
                Rectangle()
                    .fill(.white.opacity(0.04))
                    .frame(width: gap.width, height: gap.height)
                    .offset(x: gap.minX, y: gap.minY)
            }
            ForEach(layout.cells.indices, id: \.self) { i in
                let frame = layout.cells[i]
                CellView(
                    label: GazeModel.labels[i],
                    isGazed: model.zone == i,
                    progress: model.zone == i ? model.dwellProgress : 0,
                    isFlashing: model.flashZone == i
                )
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
                .onTapGesture(count: model.usingSimulated ? 2 : 1) { model.select(i) }
            }
        }
    }
}

struct CellView: View {
    let label: String
    let isGazed: Bool
    let progress: Double
    let isFlashing: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22)
                .fill(isFlashing ? Color.green.opacity(0.6) : (isGazed ? Color.cyan.opacity(0.28) : Color.white.opacity(0.08)))
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(isGazed ? Color.cyan : Color.white.opacity(0.15), lineWidth: isGazed ? 3 : 1)
            Text(label)
                .font(.system(size: 64, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            if progress > 0 {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.cyan, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .aspectRatio(1, contentMode: .fit)
                    .padding(14)
            }
        }
        .animation(.easeOut(duration: 0.15), value: isGazed)
        .animation(.easeOut(duration: 0.2), value: isFlashing)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
    }
}
