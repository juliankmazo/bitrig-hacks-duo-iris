import CoreGraphics
import Observation
import os

/// Backend-agnostic zone classifier.
/// Calibrated: feature vector -> ridge regression -> screen point (nearest-centroid fallback if singular).
/// Uncalibrated: the sample's normalized point straight onto the grid (sim default).
/// Then EMA 0.3 on the point, a dead-band around the current cell and 3-frame hysteresis.
@Observable
@MainActor
final class GazeCalibrator {
    static let zoneCount = 12
    static let emaAlpha: CGFloat = 0.3
    static let hysteresisFrames = 3
    /// Stay in the current cell until the point is this far (fraction of the cell) outside it.
    static let deadBand: CGFloat = 0.12

    /// Per-cell calibration medians (feature space).
    private(set) var medians: [[Double]?] = Array(repeating: nil, count: zoneCount)
    private(set) var regression: GazeRegression?
    /// Mean training error in points (view space) on the 12 calibration cells.
    private(set) var residualPoints: Double?
    /// The 12 medians projected through the fit (normalized), for the debug overlay.
    private(set) var projectedMedians: [CGPoint] = []
    /// Smoothed predicted point (normalized view space).
    private(set) var smoothed: CGPoint?
    private(set) var stableZone: Int?

    @ObservationIgnored private var candidate: Int?
    @ObservationIgnored private var candidateCount = 0

    var calibratedCount: Int { medians.compactMap { $0 }.count }
    /// True once a calibration run finished with enough cells (>= 7) to fit.
    private(set) var isCalibrated = false

    func clear() {
        medians = Array(repeating: nil, count: Self.zoneCount)
        regression = nil
        residualPoints = nil
        projectedMedians = []
        isCalibrated = false
        resetTracking()
    }

    func setMedian(zone: Int, _ median: [Double]) {
        guard medians.indices.contains(zone) else { return }
        medians[zone] = median
    }

    /// Fit once all 12 cells are in. Targets are the cell centers of the current layout.
    func fit(layout: GridLayout) {
        let pairs = medians.enumerated().compactMap { i, m in m.map { ($0, layout.normalizedCenters[safe: i]) } }
        let feats = pairs.map(\.0)
        let targets = pairs.compactMap(\.1)
        guard feats.count == targets.count, feats.count >= 7 else {
            GazeModel.logger.notice("fit skipped: only \(feats.count) cells")
            return
        }
        isCalibrated = true
        regression = GazeRegression.fit(features: feats, targets: targets)
        if let r = regression {
            projectedMedians = feats.compactMap { r.predict($0) }
            let errs = zip(projectedMedians, targets).map { p, t in
                hypot((p.x - t.x) * layout.size.width, (p.y - t.y) * layout.size.height)
            }
            residualPoints = errs.reduce(0, +) / Double(max(errs.count, 1))
            GazeModel.logger.notice("fit wx=\(r.wx.map { String(format: "%.4f", $0) }.joined(separator: ","), privacy: .public) wy=\(r.wy.map { String(format: "%.4f", $0) }.joined(separator: ","), privacy: .public) mean=\(r.mean.map { String(format: "%.4f", $0) }.joined(separator: ","), privacy: .public) scale=\(r.scale.map { String(format: "%.4f", $0) }.joined(separator: ","), privacy: .public) calErr=\(self.residualPoints ?? -1, format: .fixed(precision: 1))pt")
        } else {
            GazeModel.logger.notice("fit singular -> nearest-centroid fallback")
            projectedMedians = []
            residualPoints = nil
        }
        resetTracking()
    }

    private func resetTracking() {
        smoothed = nil
        candidate = nil
        candidateCount = 0
        stableZone = nil
    }

    /// Feed one sample; returns the stable zone.
    func process(_ sample: GazeSample, layout: GridLayout?) -> Int? {
        guard let layout, let point = predict(sample, layout: layout) else {
            if sample.faceDetected { return stableZone }   // blink: hold
            resetTracking()
            return nil
        }
        let a = Self.emaAlpha
        let p = smoothed.map { CGPoint(x: a * point.x + (1 - a) * $0.x, y: a * point.y + (1 - a) * $0.y) } ?? point
        smoothed = p

        // Dead-band: keep the current cell while the point is inside its expanded frame.
        if let z = stableZone, let cell = layout.cells[safe: z], layout.size.width > 0 {
            let pt = CGPoint(x: p.x * layout.size.width, y: p.y * layout.size.height)
            if cell.insetBy(dx: -cell.width * Self.deadBand, dy: -cell.height * Self.deadBand).contains(pt) {
                candidate = nil
                candidateCount = 0
                return z
            }
        }
        let raw = layout.zone(forNormalized: p)
        if raw == candidate {
            candidateCount += 1
        } else {
            candidate = raw
            candidateCount = 1
        }
        if candidateCount >= Self.hysteresisFrames || stableZone == nil {
            stableZone = raw
            candidate = nil
            candidateCount = 0
        }
        return stableZone
    }

    /// Normalized predicted point for a sample (nil when there is nothing to predict from).
    private func predict(_ sample: GazeSample, layout: GridLayout) -> CGPoint? {
        guard !sample.blink || sample.features == nil else { return nil }
        if isCalibrated, let f = sample.featureVector {
            if let r = regression { return r.predict(f) ?? sample.point }
            // Singular fit: nearest centroid in standardized feature space -> that cell's center.
            if let z = nearestMedian(to: f) { return layout.normalizedCenters[safe: z] }
        }
        return sample.point
    }

    private func nearestMedian(to f: [Double]) -> Int? {
        let all = medians.compactMap { $0 }
        guard let d = all.first?.count, d == f.count else { return nil }
        let scale = (0..<d).map { j -> Double in
            let v = all.map { $0[j] }
            let m = v.reduce(0, +) / Double(v.count)
            let s = (v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(v.count)).squareRoot()
            return s < 1e-6 ? 1 : s
        }
        var best: (Int, Double)?
        for (i, m) in medians.enumerated() {
            guard let m else { continue }
            let dist = (0..<d).map { pow((m[$0] - f[$0]) / scale[$0], 2) }.reduce(0, +)
            if best == nil || dist < best!.1 { best = (i, dist) }
        }
        return best?.0
    }
}
