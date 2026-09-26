import SwiftUI

/// Selection readout, log and status pill. In laptop pose this fills the flat bottom (table) region.
struct PanelView: View {
    let model: GazeModel
    let arrangement: GridLayout.Arrangement

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TypedText(model: model)
            Spacer(minLength: 0)
            StatusPill(model: model)
                .frame(maxWidth: .infinity)
        }
    }
}

/// The reading area: typed text, large, with a blinking cursor; the zoomed group name; a one-line log.
struct TypedText: View {
    let model: GazeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                let on = Int(ctx.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
                (Text(model.text.isEmpty ? "" : model.text)
                    + Text("|").foregroundStyle(on ? Theme.glow : .clear))
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .lineLimit(2)
                    .truncationMode(.head)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 10) {
                if let g = model.level2Group, let cell = GazeModel.cells[safe: g] {
                    Text("● \(cell.label)")
                        .font(.headline)
                        .foregroundStyle(Theme.look)
                }
                Text(model.log.isEmpty ? "log: –" : "log: " + model.log.suffix(10).joined(separator: " · "))
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .foregroundStyle(Theme.text)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(model.startOverFlash ? Color.red.opacity(0.18) : Color.white,
                    in: .rect(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
        .animation(.easeOut(duration: 0.15), value: model.startOverFlash)
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
