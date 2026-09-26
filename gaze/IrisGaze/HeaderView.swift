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
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                    let on = Int(ctx.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
                    (Text(model.text)
                        + Text("|").foregroundStyle(on ? Theme.glow : .clear))
                        .font(.system(size: 44, weight: .regular))
                        .lineLimit(2)
                        .truncationMode(.head)
                        .minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let g = model.level2Group, let cell = GazeModel.cells[safe: g] {
                    Text("● \(cell.label)")
                        .font(.headline)
                        .foregroundStyle(Theme.look)
                }
            }
            Button {
                model.speak()
            } label: {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(Theme.speaker, in: .circle)
                    .shadow(color: Theme.speaker.opacity(0.35), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Speak text")
        }
        .foregroundStyle(Theme.text)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(model.startOverFlash ? Color.red.opacity(0.15) : Color.clear,
                    in: .rect(cornerRadius: 16, style: .continuous))
        .animation(.easeOut(duration: 0.15), value: model.startOverFlash)
    }
}

struct StatusPill: View {
    let model: GazeModel

    var body: some View {
        let s = model.source.sample
        ScrollView(.horizontal) {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button(model.backend.title, systemImage: "arrow.triangle.2.circlepath.camera") { model.cycleBackend() }
                    .buttonStyle(.bordered)
                    .tint(Theme.glow)
                    .labelStyle(.titleAndIcon)
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
                Button("Retry AI") { model.retryPredictions() }
                Text(model.predictionStatus).foregroundStyle(Theme.muted)
                Button("Clear", systemImage: "trash") { model.clearLog() }
            }
            .buttonStyle(.bordered)
            .labelStyle(.titleOnly)
            .font(.caption)
        }
        }
        .scrollIndicators(.hidden)
        .frame(height: 64)
        .controlSize(.small)
        .lineLimit(1)
        .frame(maxWidth: .infinity)
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
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
