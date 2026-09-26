import CoreGraphics
import Foundation
import Observation
import os

/// Backend-agnostic zone classifier.
/// Calibrated: feature vector -> ridge regression fitted on every calibration frame (default `hybrid`: columns
/// from the eyes, rows from head pitch; CV scores every family and is logged) -> screen point.
/// Uncalibrated: the sample's normalized point straight onto the grid (sim default).
/// Then a One Euro filter, blink rewind, a dead-band around the current cell and 3-frame hysteresis.
@Observable
@MainActor
final class GazeCalibrator {
    static let zoneCount = 12
    static let hysteresisFrames = 3
    /// Stay in the current cell until the point is this far (fraction of the cell) outside it.
    static let deadBand: CGFloat = 0.12
    /// Implicit recalibration: last N dwell selections, weighted against the calibration frames.
    static let implicitCapacity = 24
    static let implicitWeight = 0.5
    /// Head-motion frames count half (calib.py sample_weights / move_weight).
    static let moveWeight = 0.5
    /// `-model auto` lets CV pick; default is the separable hybrid.
    static let preferredSpec: String? = {
        let v = UserDefaults.standard.string(forKey: "model") ?? "hybrid"
        return v == "auto" ? nil : v
    }()

    struct Frame {
        var features: [Double]
        var group: Int
        var target: CGPoint
        var pass: Int
        var stage: GazeRegression.Stage
    }

    /// Every usable calibration frame (per target: still + move phases).
    private(set) var frames: [Frame] = []
    /// Dwell selections used as labelled samples (ring buffer).
    private(set) var implicitRows: [Frame] = []
    private(set) var regression: GazeRegression?
    private(set) var names: [String] = []
    /// Mean training error in points (per target, then averaged).
    private(set) var residualPoints: Double?
    /// Leave-one-target-out error of the chosen model (points).
    private(set) var cvPoints: Double?
    /// Median prediction per calibration target (normalized) + its true target, for the debug overlay.
    private(set) var projected: [(point: CGPoint, target: CGPoint)] = []
    /// Filtered predicted point (normalized view space).
    private(set) var smoothed: CGPoint?
    private(set) var stableZone: Int?
    private(set) var isCalibrated = false

    @ObservationIgnored private var candidate: Int?
    @ObservationIgnored private var candidateCount = 0
    @ObservationIgnored private var filter = OneEuroFilter2D(minCutoff: 1.0, beta: 0.02)
    /// Blink rewind: ~300 ms of (time, point, zone).
    @ObservationIgnored private var history: [(t: TimeInterval, point: CGPoint, zone: Int?)] = []
    @ObservationIgnored private var inBlink = false

    var calibratedCells: Set<Int> { Set(frames.map(\.group).filter { $0 < Self.zoneCount }) }
    var calibratedCount: Int { calibratedCells.count }
    var modelDescription: String {
        guard let r = regression else { return isCalibrated ? "none" : "uncalibrated" }
        return "\(r.spec.name) λ\(r.lambda.formatted())"
    }

    func clear() {
        frames = []
        implicitRows = []
        regression = nil
        residualPoints = nil
        cvPoints = nil
        projected = []
        isCalibrated = false
        resetTracking()
    }

    func addFrames(_ features: [[Double]], group: Int, target: CGPoint, pass: Int, stage: GazeRegression.Stage) {
        frames += features.map { Frame(features: $0, group: group, target: target, pass: pass, stage: stage) }
    }

    /// Drop a target's frames (a rejected row is redone).
    func removeFrames(groups: Set<Int>, pass: Int) {
        frames.removeAll { groups.contains($0.group) && $0.pass == pass }
    }

    private func rows(includeImplicit: Bool) -> [GazeRegression.Row] {
        var out = frames.map {
            GazeRegression.Row(features: $0.features, target: $0.target,
                               weight: $0.stage == .move ? Self.moveWeight : 1, group: $0.group, stage: $0.stage)
        }
        if includeImplicit {
            out += implicitRows.map {
                GazeRegression.Row(features: $0.features, target: $0.target, weight: Self.implicitWeight,
                                   group: $0.group, stage: .implicit)
            }
        }
        return out
    }

    /// Fit after a calibration run on every frame; CV scores every family (logged), `hybrid` preferred.
    func fit(layout: GridLayout) {
        guard calibratedCount >= 7, let d = frames.first?.features.count else {
            GazeModel.logger.notice("fit skipped: only \(self.calibratedCount) cells")
            return
        }
        names = FeatureLayout.names(dimension: d)
        isCalibrated = true
        let calibration = rows(includeImplicit: false)
        let started = Date.now
        if let sel = GazeRegression.select(calibration, names: names, size: layout.size, preferred: Self.preferredSpec) {
            for c in sel.table.sorted(by: { $0.error < $1.error }) {
                GazeModel.logger.notice("cv \(c.spec, privacy: .public) λ=\(c.lambda) loto=\(c.error, format: .fixed(precision: 1))pt still→move=\(c.stillToMove ?? -1, format: .fixed(precision: 1))pt")
            }
            regression = sel.model
            cvPoints = sel.table.first { $0.spec == sel.model.spec.name && $0.lambda == sel.model.lambda }?.error
            GazeModel.logger.notice("chose \(sel.model.spec.name, privacy: .public) λ=\(sel.model.lambda) cv=\(self.cvPoints ?? -1, format: .fixed(precision: 1))pt from \(calibration.count) frames in \(Date.now.timeIntervalSince(started), format: .fixed(precision: 2))s")
        } else {
            regression = nil
            GazeModel.logger.notice("fit failed (singular / too few targets)")
        }
        updateDiagnostics(layout: layout)
    }

    /// Implicit recalibration: a completed dwell selection is a labelled sample. Refit with the same spec.
    func addImplicit(cell: Int, features: [Double], layout: GridLayout) {
        guard isCalibrated, let r = regression, features.count == frames.first?.features.count,
              let target = layout.normalizedCenters[safe: cell] else { return }
        implicitRows.append(Frame(features: features, group: cell, target: target, pass: -1, stage: .implicit))
        if implicitRows.count > Self.implicitCapacity { implicitRows.removeFirst(implicitRows.count - Self.implicitCapacity) }
        if let m = GazeRegression.fit(rows(includeImplicit: true), names: names, spec: r.spec, lambda: r.lambda) {
            regression = m
            updateDiagnostics(layout: layout)
            GazeModel.logger.notice("implicit refit: \(self.implicitRows.count) selections, cal err \(self.residualPoints ?? -1, format: .fixed(precision: 1))pt")
        }
    }

    private func updateDiagnostics(layout: GridLayout) {
        guard let r = regression else {
            projected = []
            residualPoints = nil
            return
        }
        var byGroup: [Int: (target: CGPoint, xs: [Double], ys: [Double])] = [:]
        for f in frames {
            guard let p = r.predict(f.features) else { continue }
            byGroup[f.group, default: (f.target, [], [])].xs.append(p.x)
            byGroup[f.group, default: (f.target, [], [])].ys.append(p.y)
        }
        projected = byGroup.values.map { v in
            (CGPoint(x: v.xs.sorted()[v.xs.count / 2], y: v.ys.sorted()[v.ys.count / 2]), v.target)
        }
        let errs = projected.map { hypot(($0.point.x - $0.target.x) * layout.size.width, ($0.point.y - $0.target.y) * layout.size.height) }
        residualPoints = errs.isEmpty ? nil : errs.reduce(0, +) / Double(errs.count)
        GazeModel.logger.notice("fit \(r.spec.name, privacy: .public) λ=\(r.lambda) wx=\(r.wx.map { String(format: "%.4f", $0) }.joined(separator: ","), privacy: .public) wy=\(r.wy.map { String(format: "%.4f", $0) }.joined(separator: ","), privacy: .public) calErr(median/target)=\(self.residualPoints ?? -1, format: .fixed(precision: 1))pt")
    }

    private func resetTracking() {
        smoothed = nil
        candidate = nil
        candidateCount = 0
        stableZone = nil
        history = []
        inBlink = false
        filter.reset()
    }

    /// Raw (unfiltered) normalized prediction for a sample; nil when there is nothing to predict from.
    func predict(_ sample: GazeSample, layout: GridLayout) -> CGPoint? {
        guard !sample.blink || sample.features == nil else { return nil }
        if isCalibrated, let f = sample.featureVector {
            return regression?.predict(f) ?? sample.point
        }
        return sample.point
    }

    /// Feed one sample; returns the stable zone.
    func process(_ sample: GazeSample, layout: GridLayout?) -> Int? {
        let now = ProcessInfo.processInfo.systemUptime
        guard let layout, layout.size.width > 0, let point = predict(sample, layout: layout) else {
            guard sample.faceDetected else {
                resetTracking()
                return nil
            }
            // Blink: the eyelid drops before the blink flag fires and drags the point down. On the first
            // blink frame, rewind to where the gaze was ~150 ms earlier and restart the filter (gaze.py).
            if sample.blink, !inBlink {
                inBlink = true
                if let past = history.last(where: { $0.t <= now - 0.15 }) ?? history.first {
                    smoothed = past.point
                    stableZone = past.zone
                    candidate = nil
                    candidateCount = 0
                }
                filter.reset()
            }
            return stableZone
        }
        inBlink = false
        // One Euro in view points, back to normalized.
        let w = layout.size.width, h = layout.size.height
        let f = filter(CGPoint(x: point.x * w, y: point.y * h), at: now)
        let p = CGPoint(x: f.x / w, y: f.y / h)
        smoothed = p
        defer {
            history.append((now, p, stableZone))
            history.removeAll { $0.t < now - 0.3 }
        }

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
}
