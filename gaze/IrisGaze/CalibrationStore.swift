import CoreGraphics
import Foundation

/// Persisted calibration: the calibration frames plus the chosen spec and lambda. Loading refits with that
/// spec/lambda (deterministic, ~0.1 s, no CV), which reproduces the exact coefficients and standardization.
/// Only valid for the same feature layout and grid geometry.
struct SavedCalibration: Codable {
    struct Frame: Codable {
        var f: [Double]
        var group: Int
        var x: Double
        var y: Double
        var pass: Int
        var stage: String
    }

    var version = 1
    var names: [String]
    var spec: String
    var lambda: Double
    var geometry: String
    var frames: [Frame]
    var savedAt: Date = .now

    static var url: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appending(path: "calibration.json")
    }

    /// Grid geometry fingerprint: the level-1 cell frames rounded to whole points.
    static func geometry(of layout: GridLayout) -> String {
        layout.cells.map { "\(Int($0.minX.rounded())),\(Int($0.minY.rounded())),\(Int($0.width.rounded())),\(Int($0.height.rounded()))" }
            .joined(separator: ";")
    }

    func save() {
        guard let url = Self.url, let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func load() -> SavedCalibration? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SavedCalibration.self, from: data)
    }

    static func delete() {
        if let url { try? FileManager.default.removeItem(at: url) }
    }
}
