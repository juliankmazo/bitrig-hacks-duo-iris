import CoreGraphics
import Observation

/// Backend-agnostic zone classifier: EMA smoothing, nearest-centroid (when calibrated)
/// or direct grid mapping (skip calibration), then 3-frame hysteresis.
@Observable
@MainActor
final class GazeCalibrator {
    static let zoneCount = 12
    static let emaAlpha: CGFloat = 0.4
    static let hysteresisFrames = 3

    private(set) var centroids: [CGPoint?] = Array(repeating: nil, count: zoneCount)
    private(set) var smoothed: CGPoint?
    private(set) var stableZone: Int?

    @ObservationIgnored private var candidate: Int?
    @ObservationIgnored private var candidateCount = 0

    var calibratedCount: Int { centroids.compactMap { $0 }.count }
    var isCalibrated: Bool { calibratedCount == Self.zoneCount }

    func clearCentroids() {
        centroids = Array(repeating: nil, count: Self.zoneCount)
    }

    func setCentroid(zone: Int, samples: [CGPoint]) {
        guard !samples.isEmpty, centroids.indices.contains(zone) else { return }
        let n = CGFloat(samples.count)
        let sx = samples.reduce(0) { $0 + $1.x }
        let sy = samples.reduce(0) { $0 + $1.y }
        centroids[zone] = CGPoint(x: sx / n, y: sy / n)
    }

    /// Feed one raw sample; returns the stable zone.
    /// `direct` maps a normalized point straight onto grid geometry (skip-calibration path).
    func process(_ point: CGPoint?, direct: (CGPoint) -> Int?) -> Int? {
        guard let point else {
            smoothed = nil
            candidate = nil
            candidateCount = 0
            stableZone = nil
            return nil
        }
        let a = Self.emaAlpha
        if let s = smoothed {
            smoothed = CGPoint(x: a * point.x + (1 - a) * s.x, y: a * point.y + (1 - a) * s.y)
        } else {
            smoothed = point
        }
        let p = smoothed!
        let raw = isCalibrated ? nearestCentroid(to: p) : direct(p)

        if raw == stableZone {
            candidate = nil
            candidateCount = 0
        } else if raw == candidate {
            candidateCount += 1
            if candidateCount >= Self.hysteresisFrames {
                stableZone = raw
                candidate = nil
                candidateCount = 0
            }
        } else {
            candidate = raw
            candidateCount = 1
        }
        return stableZone
    }

    private func nearestCentroid(to p: CGPoint) -> Int? {
        var best: (Int, CGFloat)?
        for (i, c) in centroids.enumerated() {
            guard let c else { continue }
            let d = (c.x - p.x) * (c.x - p.x) + (c.y - p.y) * (c.y - p.y)
            if best == nil || d < best!.1 { best = (i, d) }
        }
        return best?.0
    }
}
