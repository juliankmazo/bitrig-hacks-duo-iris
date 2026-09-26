import CoreGraphics
import Foundation

/// One Euro filter (Casiez et al.) on a 2-D point: steady while fixating, snappy while moving.
/// Run in view points so `beta` has intuitive units (cutoff rises by beta Hz per point/s of speed).
struct OneEuroFilter2D {
    var minCutoff: Double = 1.0
    var beta: Double = 0.02
    var dCutoff: Double = 1.0

    private var x: CGPoint?
    private var dx = CGPoint.zero
    private var t: TimeInterval?

    private static func alpha(_ cutoff: Double, _ dt: Double) -> Double {
        let tau = 1 / (2 * .pi * cutoff)
        return 1 / (1 + tau / dt)
    }

    mutating func reset() {
        x = nil
        dx = .zero
        t = nil
    }

    mutating func callAsFunction(_ p: CGPoint, at now: TimeInterval) -> CGPoint {
        guard let prev = x, let tPrev = t else {
            x = p
            t = now
            return p
        }
        let dt = max(now - tPrev, 1e-3)
        t = now
        let ad = Self.alpha(dCutoff, dt)
        let rawDx = CGPoint(x: (p.x - prev.x) / dt, y: (p.y - prev.y) / dt)
        dx = CGPoint(x: ad * rawDx.x + (1 - ad) * dx.x, y: ad * rawDx.y + (1 - ad) * dx.y)
        let speed = hypot(dx.x, dx.y)
        let a = Self.alpha(minCutoff + beta * speed, dt)
        let out = CGPoint(x: a * p.x + (1 - a) * prev.x, y: a * p.y + (1 - a) * prev.y)
        x = out
        return out
    }
}
