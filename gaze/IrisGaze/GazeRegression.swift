import CoreGraphics
import Foundation

/// Per-axis ridge regression from a gaze feature vector to a normalized screen point.
/// Mirrors `gaze/mac/fit_check.py` (numerically self-tested there).
///
/// Features are standardized by their std across the 12 calibration medians, so no single
/// feature dominates (e.g. a nearly constant eye_y can't swamp head pitch).
/// Terms: 5-D Mac vector [eye_x, eye_y, yaw, pitch, roll] -> [1, ex, ey, yaw, pitch, ex*yaw, ey*pitch];
/// 2-D point (sim / device) -> [1, x, y].
struct GazeRegression {
    static let lambda = 0.1

    let mean: [Double]
    let scale: [Double]
    let wx: [Double]
    let wy: [Double]

    static func design(_ z: [Double]) -> [Double] {
        if z.count >= 4 {
            let (ex, ey, yaw, pitch) = (z[0], z[1], z[2], z[3])
            return [1, ex, ey, yaw, pitch, ex * yaw, ey * pitch]
        }
        return [1] + Array(z.prefix(2))
    }

    /// nil if the system is singular.
    static func fit(features: [[Double]], targets: [CGPoint]) -> GazeRegression? {
        guard let d = features.first?.count, features.count == targets.count, features.count >= 3 else { return nil }
        let n = Double(features.count)
        var mean = [Double](repeating: 0, count: d)
        for f in features { for j in 0..<d { mean[j] += f[j] / n } }
        var scale = [Double](repeating: 0, count: d)
        for f in features { for j in 0..<d { scale[j] += (f[j] - mean[j]) * (f[j] - mean[j]) / n } }
        scale = scale.map { $0.squareRoot() < 1e-6 ? 1 : $0.squareRoot() }

        let rows = features.map { f in design((0..<d).map { (f[$0] - mean[$0]) / scale[$0] }) }
        let p = rows[0].count
        // A = X^T X + lambda I (no penalty on the bias), bx = X^T tx, by = X^T ty
        var a = [[Double]](repeating: [Double](repeating: 0, count: p), count: p)
        var bx = [Double](repeating: 0, count: p), by = [Double](repeating: 0, count: p)
        for (r, t) in zip(rows, targets) {
            for i in 0..<p {
                bx[i] += r[i] * t.x
                by[i] += r[i] * t.y
                for j in 0..<p { a[i][j] += r[i] * r[j] }
            }
        }
        for i in 1..<p { a[i][i] += lambda }
        guard let wx = solve(a, bx), let wy = solve(a, by) else { return nil }
        return GazeRegression(mean: mean, scale: scale, wx: wx, wy: wy)
    }

    func predict(_ f: [Double]) -> CGPoint? {
        guard f.count == mean.count else { return nil }
        let row = Self.design((0..<f.count).map { (f[$0] - mean[$0]) / scale[$0] })
        var x = 0.0, y = 0.0
        for i in row.indices { x += row[i] * wx[i]; y += row[i] * wy[i] }
        return CGPoint(x: x, y: y)
    }

    /// Gaussian elimination with partial pivoting.
    private static func solve(_ a0: [[Double]], _ b0: [Double]) -> [Double]? {
        var a = a0, b = b0
        let n = b.count
        for c in 0..<n {
            guard let piv = (c..<n).max(by: { abs(a[$0][c]) < abs(a[$1][c]) }), abs(a[piv][c]) > 1e-10 else { return nil }
            a.swapAt(c, piv); b.swapAt(c, piv)
            for r in (c + 1)..<n where r < n {
                let f = a[r][c] / a[c][c]
                if f == 0 { continue }
                for k in c..<n { a[r][k] -= f * a[c][k] }
                b[r] -= f * b[c]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for r in stride(from: n - 1, through: 0, by: -1) {
            var s = b[r]
            for k in (r + 1)..<n where k < n { s -= a[r][k] * x[k] }
            x[r] = s / a[r][r]
        }
        return x
    }
}
