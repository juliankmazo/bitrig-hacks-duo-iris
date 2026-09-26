import CoreGraphics
import Foundation

/// Which terms the regression uses. Feature layout (Mac):
/// [eye_x, eye_y, yaw, pitch, roll, left_x, left_y, right_x, right_y] (per-eye optional).
/// A 2-D point (sim / device) always uses [1, x, y].
enum GazeModelSpec: String, CaseIterable {
    case linear, quadratic, perEye, headOnly, eyesOnly

    func terms(_ z: [Double]) -> [Double] {
        guard z.count >= 4 else { return [1] + Array(z.prefix(2)) }
        let (ex, ey, yaw, pitch) = (z[0], z[1], z[2], z[3])
        switch self {
        case .linear:
            return [1, ex, ey, yaw, pitch, ex * yaw, ey * pitch]
        case .quadratic:
            return [1, ex, ey, yaw, pitch, ex * yaw, ey * pitch, ex * ex, ey * ey, ex * ey, yaw * yaw, pitch * pitch]
        case .perEye:
            guard z.count >= 9 else { return Self.linear.terms(z) }
            return [1, z[5], z[6], z[7], z[8], yaw, pitch, ex * yaw, ey * pitch]
        case .headOnly:
            return [1, yaw, pitch, yaw * pitch]
        case .eyesOnly:
            return [1, ex, ey, ex * ey]
        }
    }

    /// Candidates the in-app cross-validation chooses between.
    static func candidates(dimension d: Int) -> [GazeModelSpec] {
        if d < 4 { return [.linear] }
        return d >= 9 ? allCases : allCases.filter { $0 != .perEye }
    }
}

/// Weighted ridge regression from a gaze feature vector to a normalized screen point, one fit per axis.
/// Mirrors `gaze/mac/replay.py`.
///
/// Features are standardized by their spread across the calibration rows, with a floor per feature
/// (0.03 rad for head angles): with a still-head calibration, yaw/pitch barely vary, and dividing by that
/// tiny spread would turn a 2° head turn into a huge input.
struct GazeRegression {
    let spec: GazeModelSpec
    let lambda: Double
    let mean: [Double]
    let scale: [Double]
    let wx: [Double]
    let wy: [Double]

    static let lambdas: [Double] = [0.1, 0.3, 1, 3, 10]

    static func floors(dimension d: Int) -> [Double] {
        (0..<d).map { j in d >= 4 && (2...4).contains(j) ? 0.03 : 0.01 }
    }

    struct Row {
        var features: [Double]
        var target: CGPoint
        var weight: Double = 1
        /// Cell id: leave-one-cell-out holds out all rows of a cell together.
        var group: Int
    }

    static func fit(_ rows: [Row], spec: GazeModelSpec, lambda: Double) -> GazeRegression? {
        guard let d = rows.first?.features.count, rows.count >= 3, rows.allSatisfy({ $0.features.count == d }) else { return nil }
        let n = Double(rows.count)
        var mean = [Double](repeating: 0, count: d)
        for r in rows { for j in 0..<d { mean[j] += r.features[j] / n } }
        var variance = [Double](repeating: 0, count: d)
        for r in rows { for j in 0..<d { variance[j] += pow(r.features[j] - mean[j], 2) / n } }
        let fl = floors(dimension: d)
        let scale = (0..<d).map { max(variance[$0].squareRoot(), fl[$0]) }

        let x = rows.map { r in spec.terms((0..<d).map { (r.features[$0] - mean[$0]) / scale[$0] }) }
        let p = x[0].count
        var a = [[Double]](repeating: [Double](repeating: 0, count: p), count: p)
        var bx = [Double](repeating: 0, count: p), by = [Double](repeating: 0, count: p)
        for (xi, r) in zip(x, rows) {
            let w = r.weight
            for i in 0..<p {
                bx[i] += w * xi[i] * r.target.x
                by[i] += w * xi[i] * r.target.y
                for j in 0..<p { a[i][j] += w * xi[i] * xi[j] }
            }
        }
        for i in 1..<p { a[i][i] += lambda }
        guard let wx = solve(a, bx), let wy = solve(a, by) else { return nil }
        return GazeRegression(spec: spec, lambda: lambda, mean: mean, scale: scale, wx: wx, wy: wy)
    }

    func predict(_ f: [Double]) -> CGPoint? {
        guard f.count == mean.count else { return nil }
        let t = spec.terms((0..<f.count).map { (f[$0] - mean[$0]) / scale[$0] })
        var x = 0.0, y = 0.0
        for i in t.indices { x += t[i] * wx[i]; y += t[i] * wy[i] }
        return CGPoint(x: x, y: y)
    }

    struct Selection {
        var model: GazeRegression
        /// Leave-one-cell-out mean error (points) per candidate, for the log.
        var table: [(spec: GazeModelSpec, lambda: Double, error: Double)]
    }

    /// Leave-one-cell-out CV over spec x lambda; error measured in view points.
    static func select(_ rows: [Row], size: CGSize) -> Selection? {
        guard let d = rows.first?.features.count else { return nil }
        let groups = Set(rows.map(\.group))
        var table: [(spec: GazeModelSpec, lambda: Double, error: Double)] = []
        for spec in GazeModelSpec.candidates(dimension: d) {
            for lambda in lambdas {
                var errors: [Double] = []
                for g in groups {
                    let train = rows.filter { $0.group != g }
                    guard let m = fit(train, spec: spec, lambda: lambda) else { errors = []; break }
                    for r in rows where r.group == g {
                        guard let p = m.predict(r.features) else { continue }
                        errors.append(hypot((p.x - r.target.x) * size.width, (p.y - r.target.y) * size.height))
                    }
                }
                if !errors.isEmpty { table.append((spec, lambda, errors.reduce(0, +) / Double(errors.count))) }
            }
        }
        guard let best = table.min(by: { $0.error < $1.error }),
              let model = fit(rows, spec: best.spec, lambda: best.lambda) else { return nil }
        return Selection(model: model, table: table)
    }

    /// Gaussian elimination with partial pivoting.
    private static func solve(_ a0: [[Double]], _ b0: [Double]) -> [Double]? {
        var a = a0, b = b0
        let n = b.count
        for c in 0..<n {
            guard let piv = (c..<n).max(by: { abs(a[$0][c]) < abs(a[$1][c]) }), abs(a[piv][c]) > 1e-10 else { return nil }
            a.swapAt(c, piv); b.swapAt(c, piv)
            for r in (c + 1)..<n {
                let f = a[r][c] / a[c][c]
                if f == 0 { continue }
                for k in c..<n { a[r][k] -= f * a[c][k] }
                b[r] -= f * b[c]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for r in stride(from: n - 1, through: 0, by: -1) {
            var s = b[r]
            for k in (r + 1)..<n { s -= a[r][k] * x[k] }
            x[r] = s / a[r][r]
        }
        return x
    }
}
