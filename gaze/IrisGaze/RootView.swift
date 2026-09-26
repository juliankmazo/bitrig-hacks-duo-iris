import SwiftUI

struct RootView: View {
    @Bindable var model: GazeModel

    var body: some View {
        GeometryReader { proxy in
            // Read reserved regions on EVERY layout pass: they are empty on the first one.
            let layout = GridLayout.make(
                size: proxy.size,
                divisions: proxy.reservedRegions(kind: .division),
                occlusions: proxy.reservedRegions(kind: .occlusion)
            )
            ZStack(alignment: .topLeading) {
                Color.black

                switch model.screen {
                case .idle:
                    IdleView()
                case .calibration:
                    CalibrationView(model: model, layout: layout)
                case .grid:
                    GridView(model: model, layout: layout)
                }

                if model.screen != .idle {
                    HeaderView(model: model)
                        .frame(width: layout.header.width, height: layout.header.height)
                        .offset(x: layout.header.minX, y: layout.header.minY)

                    GazeCursor(model: model, size: proxy.size)
                }
            }
            .coordinateSpace(.named("root"))
            .contentShape(.rect)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("root"))
                    .onChanged { model.fingerMoved(to: $0.location) },
                isEnabled: model.usingSimulated && model.screen != .idle
            )
            .onChange(of: layout, initial: true) { _, new in model.layout = new }
        }
        .ignoresSafeArea()
        .onHingeChange { _, ctx in
            withAnimation(.spring) { model.apply(hinge: ctx.hinge) }
        }
    }
}

/// Where the model thinks you are looking (smoothed).
struct GazeCursor: View {
    let model: GazeModel
    let size: CGSize

    var body: some View {
        if let p = model.calibrator.smoothed {
            Circle()
                .strokeBorder(.white.opacity(0.9), lineWidth: 2)
                .background(Circle().fill(.cyan.opacity(0.25)))
                .frame(width: 28, height: 28)
                .position(x: p.x * size.width, y: p.y * size.height)
                .allowsHitTesting(false)
        }
    }
}
