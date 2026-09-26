import SwiftUI

struct RootView: View {
    let model: GazeModel

    var body: some View {
        GeometryReader { proxy in
            // Read reserved regions on EVERY layout pass: they are empty on the first one.
            let layout = GridLayout.make(
                size: proxy.size,
                divisions: proxy.reservedRegions(kind: .division),
                occlusions: proxy.reservedRegions(kind: .occlusion),
                simulatedPose: SimulatedPose.launchValue
            )
            ZStack(alignment: .topLeading) {
                Theme.background

                switch model.screen {
                case .idle:
                    IdleView()
                case .calibration:
                    CalibrationView(model: model, layout: layout)
                case .grid:
                    GridView(model: model, layout: layout)
                    if model.needsCalibration, let first = layout.cells.first, let last = layout.cells.last {
                        CalibrateCallToAction(model: model)
                            .frame(width: first.union(last).width, height: first.union(last).height)
                            .offset(x: first.minX, y: first.minY)
                    }
                }

                if model.screen != .idle {
                    PanelView(model: model, arrangement: layout.arrangement)
                        .frame(width: layout.panel.width, height: layout.panel.height, alignment: .topLeading)
                        .offset(x: layout.panel.minX, y: layout.panel.minY)

                    if model.screen == .grid {
                        if model.showDebug && model.calibrator.isCalibrated {
                            DebugOverlay(model: model, layout: layout)
                        } else if !model.calibrator.isCalibrated && !model.needsCalibration {
                            GazeCursor(model: model, size: proxy.size)
                        }
                    }
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

/// Shown over the grid when a raw-feature backend (Mac webcam / device) is active but not calibrated.
struct CalibrateCallToAction: View {
    let model: GazeModel

    var body: some View {
        VStack(spacing: 12) {
            Text("\(model.source.name) connected")
                .font(.headline)
                .foregroundStyle(Theme.muted)
            Button {
                model.startCalibration()
            } label: {
                Label("Calibrate", systemImage: "scope")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.look)
            Text("Look at 12 cells, one at a time (\(model.calibrator.calibratedCount)/12)")
                .font(.callout)
                .foregroundStyle(Theme.muted)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.opacity(0.8), in: .rect(cornerRadius: 20))
    }
}

/// Where the model thinks you are looking (smoothed, uncalibrated/direct mapping only).
struct GazeCursor: View {
    let model: GazeModel
    let size: CGSize

    var body: some View {
        if let p = model.calibrator.smoothed {
            Circle()
                .strokeBorder(.white.opacity(0.9), lineWidth: 2)
                .background(Circle().fill(Theme.glow.opacity(0.25)))
                .frame(width: 28, height: 28)
                .position(x: p.x * size.width, y: p.y * size.height)
                .allowsHitTesting(false)
        }
    }
}
