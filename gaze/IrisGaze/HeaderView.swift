import SwiftUI

/// Top strip: selection readout + log on the leading side, status tile + controls trailing.
/// Leading/trailing keeps both halves on their own side of a vertical fold.
struct HeaderView: View {
    @Bindable var model: GazeModel

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("selected: \(model.selected ?? "–")")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(model.log.isEmpty ? "log: –" : "log: " + model.log.suffix(24).joined(separator: " "))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            StatusTile(model: model)
        }
        .foregroundStyle(.white)
    }
}

struct StatusTile: View {
    @Bindable var model: GazeModel

    var body: some View {
        let s = model.source.sample
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Label(model.source.name, systemImage: "camera")
                Text("face \(s.faceDetected ? "✓" : "✗")  blink \(s.blink ? "●" : "○")")
                Text("calibrated \(model.calibrator.calibratedCount)/12")
                Text(model.hingeText)
            }
            .font(.caption.monospaced())
            .fixedSize()

            VStack(alignment: .trailing, spacing: 4) {
                Toggle("Tour", isOn: Binding(get: { model.simulated.tourEnabled }, set: { model.simulated.tourEnabled = $0 }))
                    .toggleStyle(.button)
                    .disabled(!model.usingSimulated)
                HStack(spacing: 4) {
                    Button("Cal", systemImage: "scope") { model.startCalibration() }
                        .labelStyle(.titleOnly)
                    Button("Clear", systemImage: "trash") { model.clearLog() }
                        .labelStyle(.titleOnly)
                }
                Toggle("Sim", isOn: Binding(get: { model.usingSimulated }, set: { model.useSimulated($0) }))
                    .toggleStyle(.button)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .font(.caption)
            .fixedSize()
        }
        .padding(10)
        .background(.white.opacity(0.08), in: .rect(cornerRadius: 14))
    }
}
