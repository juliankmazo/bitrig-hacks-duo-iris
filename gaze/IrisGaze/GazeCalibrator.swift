import CoreGraphics
import Foundation
import Observation
import os

/// Backend-agnostic zone classifier.
/// Calibrated: feature vector -> ridge regression (model + lambda picked by leave-one-cell-out CV)
/// -> screen point (nearest-centroid fallback if singular).
/// Uncalibrated: the sample's normalized point straight onto the grid (sim default).
/// Then a One Euro filter on the point, a dead-band around the current cell and 3-frame hysteresis.
@Observable
@MainActor
final class GazeCalibrator {
    static let zoneCount = 12
    static let hysteresisFrames = 3
    /// Stay in the current cell until the point is this far (fraction of the cell) outside it.
    static let deadBand: CGFloat = 0.12
    /// Implicit recalibration: last N dwell selections, weighted against the calibration medians.
    static let implicitCapacity = 24
    static let implicitWeight = 0.5

    struct CalRow {
        var features: [Double]
        var cell: Int
        var pass: Int
    }

    /// Calibration medians, one per cell per pass.
    private(set) var calRows: [CalRow] = []
    /// Dwell selections used as labelled samples (ring buffer).
    private(set) var implicitRows: [CalRow] = []
    private(set) var regression: GazeRegression?
    /// Mean training error in points (view space) on the calibration rows.
    private(set) var residualPoints: Double?
    /// Leave-one-cell-out error of the chosen model (points).
    private(set) var cvPoints: Double?
    /// The calibration medians projected through the fit (normalized) + their cell, for the debug overlay.
    private(set) var projected: [(point: CGPoint, cell: Int)] = []
    /// Filtered predicted point (normalized view space).
    private(set) var smoothed: CGPoint?
    private(set) var stableZone: Int?
    private(set) var isCalibrated = false

    @ObservationIgnored private var candidate: Int?
    @ObservationIgnored private var candidateCount = 0
    @ObservationIgnored private var filter = OneEuroFilter2D(minCutoff: 1.0, beta: 0.02)

    var calibratedCells: Set<Int> { Set(calRows.map(\.cell)) }
    var calibratedCount: Int { calibratedCells.count }
    var modelDescription: String {
        guard let r = regression else { return isCalibrated ? "centroid" : "none" }
        return "\(r.spec.rawValue) λ\(r.lambda.formatted())"
    }

    func clear() {
        calRows = []
        implicitRows = []
        regression = nil
        residualPoints = nil
        cvPoints = nil
        projected = []
        isCalibrated = false
        resetTracking()
    }

    func addMedian(cell: Int, pass: Int, _ median: [Double]) {
        calRows.append(CalRow(features: median, cell: cell, pass: pass))
    }

    private func rows(layout: GridLayout, includeImplicit: Bool) -> [GazeRegression.Row] {
        let centers = layout.normalizedCenters
        var out = calRows.compactMap { r in
            centers[safe: r.cell].map { GazeRegression.Row(features: r.features, target: $0, weight: 1, group: r.cell) }
        }
        if includeImplicit {
            out += implicitRows.compactMap { r in
                centers[safe: r.cell].map {
                    GazeRegression.Row(features: r.features, target: $0, weight: Self.implicitWeight, group: r.cell)
                }
            }
        }
        return out
    }

    /// Fit after a calibration run: CV picks the model + lambda on the calibration rows only.
    func fit(layout: GridLayout) {
        guard calibratedCount >= 7 else {
            GazeModel.logger.notice("fit skipped: only \(self.calibratedCount) cells")
            return
        }
        isCalibrated = true
        let calibration = rows(layout: layout, includeImplicit: false)
        if let sel = GazeRegression.select(calibration, size: layout.size) {
            for row in sel.table.sorted(by: { $0.error < $1.error }) {
                GazeModel.logger.notice("cv \(row.spec.rawValue, privacy: .public) λ=\(row.lambda) err=\(row.error, format: .fixed(precision: 1))pt")
            }
            let best = sel.table.min { $0.error < $1.error }
            cvPoints = best?.error
            regression = sel.model
            GazeModel.logger.notice("chose \(sel.model.spec.rawValue, privacy: .public) λ=\(sel.model.lambda) cv=\(best?.error ?? -1, format: .fixed(precision: 1))pt")
        } else {
            regression = nil
            GazeModel.logger.notice("fit singular -> nearest-centroid fallback")
        }
        updateDiagnostics(layout: layout)
    }

    /// Implicit recalibration: a completed dwell selection is a labelled sample. Refit with the same spec.
    func addImplicit(cell: Int, features: [Double], layout: GridLayout) {
        guard isCalibrated, let spec = regression?.spec, let lambda = regression?.lambda,
              features.count == calRows.first?.features.count else { return }
        implicitRows.append(CalRow(features: features, cell: cell, pass: -1))
        if implicitRows.count > Self.implicitCapacity { implicitRows.removeFirst(implicitRows.count - Self.implicitCapacity) }
        if let m = GazeRegression.fit(rows(layout: layout, includeImplicit: true), spec: spec, lambda: lambda) {
            regression = m
            updateDiagnostics(layout: layout)
            GazeModel.logger.notice("implicit refit: \(self.implicitRows.count) selections, cal err \(self.residualPoints ?? -1, format: .fixed(precision: 1))pt")
        }
    }

    private func updateDiagnostics(layout: GridLayout) {
        let centers = layout.normalizedCenters
        guard let r = regression else {
            projected = []
            residualPoints = nil
            return
        }
        projected = calRows.compactMap { row in r.predict(row.features).map { ($0, row.cell) } }
        let errs = projected.compactMap { p, cell in
            centers[safe: cell].map { hypot((p.x - $0.x) * layout.size.width, (p.y - $0.y) * layout.size.height) }
        }
        residualPoints = errs.isEmpty ? nil : errs.reduce(0, +) / Double(errs.count)
        GazeModel.logger.notice("fit \(r.spec.rawValue, privacy: .public) λ=\(r.lambda) wx=\(r.wx.map { String(format: "%.4f", $0) }.joined(separator: ","), privacy: .public) wy=\(r.wy.map { String(format: "%.4f", $0) }.joined(separator: ","), privacy: .public) calErr=\(self.residualPoints ?? -1, format: .fixed(precision: 1))pt")
    }

    private func resetTracking() {
        smoothed = nil
        candidate = nil
        candidateCount = 0
        stableZone = nil
        filter.reset()
    }

    /// Raw (unfiltered) normalized prediction for a sample; nil when there is nothing to predict from.
    func predict(_ sample: GazeSample, layout: GridLayout) -> CGPoint? {
        guard !sample.blink || sample.features == nil else { return nil }
        if isCalibrated, let f = sample.featureVector {
            if let r = regression { return r.predict(f) ?? sample.point }
            if let z = nearestMedian(to: f) { return layout.normalizedCenters[safe: z] }
        }
        return sample.point
    }

    /// Feed one sample; returns the stable zone.
    func process(_ sample: GazeSample, layout: GridLayout?) -> Int? {
        guard let layout, layout.size.width > 0, let point = predict(sample, layout: layout) else {
            if sample.faceDetected { return stableZone }   // blink: hold
            resetTracking()
            return nil
        }
        // One Euro in view points, back to normalized.
        let w = layout.size.width, h = layout.size.height
        let f = filter(CGPoint(x: point.x * w, y: point.y * h), at: ProcessInfo.processInfo.systemUptime)
        let p = CGPoint(x: f.x / w, y: f.y / h)
        smoothed = p

        // Dead-band: keep the current cell while the point is inside its expanded frame.
        if let z = stableZone, let cell = layout.cells[safe: z] {
            if cell.insetBy(dx: -cell.width * Self.deadBand, dy: -cell.height * Self.deadBand).contains(f) {
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

    private func nearestMedian(to f: [Double]) -> Int? {
        let all = calRows.map(\.features)
        guard let d = all.first?.count, d == f.count else { return nil }
        let scale = (0..<d).map { j -> Double in
            let v = all.map { $0[j] }
            let m = v.reduce(0, +) / Double(v.count)
            let s = (v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(v.count)).squareRoot()
            return s < 1e-6 ? 1 : s
        }
        return calRows.min { a, b in
            let da = (0..<d).map { pow((a.features[$0] - f[$0]) / scale[$0], 2) }.reduce(0, +)
            let db = (0..<d).map { pow((b.features[$0] - f[$0]) / scale[$0], 2) }.reduce(0, +)
            return da < db
        }?.cell
    }
}
