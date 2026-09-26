import SwiftUI

/// Selection readout, log and status pill. In laptop pose this fills the flat bottom (table) region.
struct PanelView: View {
    let model: GazeModel
    let arrangement: GridLayout.Arrangement

    var body: some View {
        if arrangement == .laptop {
            VStack(alignment: .leading, spacing: 10) {
                readout
                Spacer(minLength: 0)
                StatusPill(model: model)
                    .frame(maxWidth: .infinity)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                readout
                StatusPill(model: model)
            }
        }
    }

    private var readout: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("selected: \(model.selected ?? "–")")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(model.log.isEmpty ? "log: –" : "log: " + model.log.suffix(12).joined(separator: " · "))
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .foregroundStyle(Theme.text)
    }
}

struct StatusPill: View {
    let model: GazeModel

    var body: some View {
        let s = model.source.sample
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button(model.backend.title, systemImage: "arrow.triangle.2.circlepath.camera") { model.cycleBackend() }
                    .buttonStyle(.bordered)
                    .tint(Theme.glow)
                    .labelStyle(.titleAndIcon)
                    .fixedSize()
                indicator("face", on: s.faceDetected, color: .green)
                indicator("blink", on: s.blink, color: .yellow)
                Text("cal \(model.calibrator.calibratedCount)/12")
                if let err = model.calibrator.residualPoints {
                    Text("cal err \(Int(err.rounded()))px")
                        .foregroundStyle(err < 30 ? .green : err < 60 ? .yellow : .red)
                }
                if let val = model.validationAccuracy {
                    Text("val \(Int((val * 100).rounded()))%")
                        .foregroundStyle(val >= 0.8 ? .green : val >= 0.5 ? .yellow : .red)
                }
                if let f = s.featureVector, let i = FeatureLayout.names(dimension: f.count).firstIndex(of: "pitch") {
                    Text("pitch \(f[i] * 180 / .pi, specifier: "%+.1f")°")
                        .foregroundStyle(Theme.look)
                }
                Text("\(model.fps) fps")
                Text(model.hingeText)
                    .foregroundStyle(Theme.muted)
            }
            .font(.caption.monospacedDigit())
            HStack(spacing: 8) {
                Button("Calibrate", systemImage: "scope") { model.startCalibration() }
                    .tint(Theme.look)
                Toggle("Test", systemImage: "scope",
                       isOn: Binding(get: { model.showDebug }, set: { _ in model.test() }))
                    .toggleStyle(.button)
                Button("Reset cal", systemImage: "arrow.counterclockwise") { model.resetCalibration() }
                Button("\(model.calPasses)× pass", systemImage: "repeat") { model.calPasses = model.calPasses == 1 ? 2 : 1 }
                if model.usingSimulated {
                    Toggle("Tour", systemImage: "figure.walk",
                           isOn: Binding(get: { model.simulated.tourEnabled }, set: { model.simulated.tourEnabled = $0 }))
                        .toggleStyle(.button)
                }
                Button("Clear", systemImage: "trash") { model.clearLog() }
            }
            .buttonStyle(.bordered)
            .labelStyle(.titleOnly)
            .font(.caption)
        }
        .controlSize(.small)
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.panel, in: .capsule)
        .overlay(Capsule().strokeBorder(Theme.cellBorder))
    }

    private func indicator(_ title: String, on: Bool, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(on ? color : Color.gray.opacity(0.4)).frame(width: 9, height: 9)
            Text(title)
        }
    }
}
