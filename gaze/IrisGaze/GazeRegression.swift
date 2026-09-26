import CoreGraphics
import Foundation

/// Named feature layout of a backend's feature vector.
enum FeatureLayout {
    /// Sim / device: a normalized 2-D point.
    static let point = ["x", "y"]
    /// Mac server `f2`: pose-invariant eye features (canonical face frame, / eye width), head pose + position,
    /// blendshape eye direction. `eye_v` / `c_ev_*` are measured from the eye-corner line, not the lids.
    static let mac = ["eye_h", "eye_v", "lid_v", "yaw", "pitch", "roll", "nose_x", "nose_y", "head_z", "face_w",
                      "bs_h", "bs_v", "c_eh_l", "c_eh_r", "c_ev_l", "c_ev_r", "c_lid_l", "c_lid_r", "c_ap_l", "c_ap_r"]
    /// Older Mac server (`f` + `fl`/`fr`).
    static let macLegacy = ["eye_h", "eye_v", "yaw", "pitch", "roll", "l_x", "l_y", "r_x", "r_y"]

    static func names(dimension d: Int) -> [String] {
        switch d {
        case mac.count: mac
        case macLegacy.count: macLegacy
        default: Array(point.prefix(d))
        }
    }

    /// Standardization floors in physical units (calib.py SD_FLOOR): with a still-head calibration head
    /// features barely vary, and dividing by that tiny spread would blow a 2° turn up into a huge input.
    static let floors: [String: Double] = ["yaw": 0.03, "pitch": 0.03, "roll": 0.03, "nose_x": 0.01, "nose_y": 0.01,
                                           "head_z": 0.01, "face_w": 0.005]
}

/// Terms for one axis: linear features, quadratic (squares + pairwise among `quad`), extra products.
/// Quadratic and product terms are dropped with fewer than 7 calibration targets (calib.py quad_on).
struct TermSet {
    var lin: [String]
    var quad: [String] = []
    var inter: [(String, String)] = []

    var names: Set<String> { Set(lin + quad + inter.flatMap { [$0.0, $0.1] }) }
}

/// A model family. `y == nil` means both axes share the same terms; `hybrid` is separable.
struct GazeModelSpec {
    let name: String
    let x: TermSet
    var y: TermSet?
    var yTerms: TermSet { y ?? x }

    static let pointLinear = GazeModelSpec(name: "linear", x: TermSet(lin: ["x", "y"]))

    /// Separable: columns from the eyes (+ yaw), rows from head pitch / position (+ weak eye_v).
    /// Julian's recordings: eye_x separates columns at ~9σ per step; there is no vertical eye signal at
    /// webcam resolution, so rows come from pointing the nose.
    static let hybrid = GazeModelSpec(name: "hybrid",
                                      x: TermSet(lin: ["eye_h", "c_eh_l", "c_eh_r", "yaw"]),
                                      y: TermSet(lin: ["pitch", "nose_y", "head_z", "eye_v"]))
    static let hybridLegacy = GazeModelSpec(name: "hybrid",
                                            x: TermSet(lin: ["eye_h", "l_x", "r_x", "yaw"]),
                                            y: TermSet(lin: ["pitch", "eye_v"]))
    static let linear = GazeModelSpec(name: "linear", x: TermSet(lin: ["eye_h", "eye_v", "yaw", "pitch"],
                                                                 inter: [("yaw", "eye_h"), ("pitch", "eye_v")]))
    static let perEye = GazeModelSpec(name: "perEye", x: TermSet(lin: ["c_eh_l", "c_eh_r", "c_ev_l", "c_ev_r",
                                                                       "c_lid_l", "c_lid_r", "yaw", "pitch"]))
    static let perEyeLegacy = GazeModelSpec(name: "perEye", x: TermSet(lin: ["l_x", "l_y", "r_x", "r_y", "yaw", "pitch"]))
    static let headOnly = GazeModelSpec(name: "headOnly", x: TermSet(lin: ["yaw", "pitch", "roll", "nose_x", "nose_y", "head_z"],
                                                                     quad: ["yaw", "pitch"]))
    static let headOnlyLegacy = GazeModelSpec(name: "headOnly", x: TermSet(lin: ["yaw", "pitch", "roll"], quad: ["yaw", "pitch"]))
    private static let physInter = [("yaw", "eye_h"), ("pitch", "eye_v"), ("pitch", "lid_v"), ("yaw", "eye_v"),
                                    ("pitch", "eye_h"), ("yaw", "pitch")]
    static let phys = GazeModelSpec(name: "phys", x: TermSet(lin: ["eye_h", "eye_v", "lid_v", "yaw", "pitch", "roll",
                                                                   "nose_x", "nose_y", "head_z"],
                                                             quad: ["eye_h", "eye_v", "lid_v"], inter: physInter))
    static let physBS = GazeModelSpec(name: "physBS", x: TermSet(lin: ["eye_h", "eye_v", "lid_v", "bs_h", "bs_v", "yaw", "pitch",
                                                                       "roll", "nose_x", "nose_y", "head_z"],
                                                                 quad: ["eye_h", "eye_v", "lid_v"], inter: physInter))

    /// Available specs for a layout, default (`hybrid`) first.
    static func candidates(names: [String]) -> [GazeModelSpec] {
        let all: [GazeModelSpec] = [.hybrid, .hybridLegacy, .pointLinear, .linear, .perEye, .perEyeLegacy,
                                    .headOnly, .headOnlyLegacy, .phys, .physBS]
        let have = Set(names)
        var seen = Set<String>()
        return all.filter { spec in
            spec.x.names.union(spec.yTerms.names).isSubset(of: have) && seen.insert(spec.name).inserted
        }
    }
}

/// Standardization + design-matrix builder for one axis (calib.py Design).
struct GazeDesign {
    let cols: [Int]
    let mean: [Double]
    let scale: [Double]
    let q: [Int]
    let inter: [(Int, Int)]
    let quadOn: Bool

    init?(terms: TermSet, names: [String], rows: [[Double]], quadOn: Bool) {
        guard !rows.isEmpty else { return nil }
        let idx = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($1, $0) })
        let cols = terms.lin.compactMap { idx[$0] }
        guard cols.count == terms.lin.count else { return nil }
        let n = Double(rows.count)
        var mean = [Double](repeating: 0, count: cols.count)
        for r in rows { for (k, j) in cols.enumerated() { mean[k] += r[j] / n } }
        var variance = [Double](repeating: 0, count: cols.count)
        for r in rows { for (k, j) in cols.enumerated() { variance[k] += pow(r[j] - mean[k], 2) / n } }
        scale = (0..<cols.count).map { k in max(variance[k].squareRoot() + 1e-6, FeatureLayout.floors[terms.lin[k]] ?? 0) }
        self.cols = cols
        self.mean = mean
        self.quadOn = quadOn
        q = terms.quad.compactMap { terms.lin.firstIndex(of: $0) }
        inter = terms.inter.compactMap { a, b in
            guard let i = terms.lin.firstIndex(of: a), let j = terms.lin.firstIndex(of: b) else { return nil }
            return (i, j)
        }
    }

    func callAsFunction(_ f: [Double]) -> [Double] {
        let z = cols.enumerated().map { k, j in (f[j] - mean[k]) / scale[k] }
        var t = [1.0] + z
        if quadOn {
            for a in q.indices {
                t.append(z[q[a]] * z[q[a]])
                for b in (a + 1)..<q.count { t.append(z[q[a]] * z[q[b]]) }
            }
            for (a, b) in inter { t.append(z[a] * z[b]) }
        }
        return t
    }
}

/// Gram accumulators for one axis: A = XᵀWX, b = XᵀW t.
private struct Gram {
    var a: [[Double]]
    var b: [Double]

    init(p: Int) {
        a = Array(repeating: Array(repeating: 0, count: p), count: p)
        b = Array(repeating: 0, count: p)
    }

    mutating func add(_ x: [Double], _ t: Double, _ w: Double) {
        for i in x.indices {
            let wi = w * x[i]
            b[i] += wi * t
            for j in x.indices { a[i][j] += wi * x[j] }
        }
    }

    func minus(_ o: Gram) -> Gram {
        var g = self
        for i in a.indices {
            g.b[i] -= o.b[i]
            for j in a.indices { g.a[i][j] -= o.a[i][j] }
        }
        return g
    }

    func solve(lambda: Double) -> [Double]? {
        var m = a
        for i in 1..<m.count { m[i][i] += lambda }   // don't shrink the bias
        return GazeRegression.solve(m, b)
    }
}

/// Weighted ridge regression from a gaze feature vector to a normalized screen point, one design per axis.
/// Mirrors `gaze/mac/replay.py`.
struct GazeRegression {
    let spec: GazeModelSpec
    let lambda: Double
    let designX: GazeDesign
    let designY: GazeDesign
    let wx: [Double]
    let wy: [Double]

    static let lambdas: [Double] = [0.3, 1, 3, 10, 30]

    enum Stage: String { case still, move, point, implicit }

    struct Row {
        var features: [Double]
        var target: CGPoint
        var weight: Double = 1
        /// Leave-one-target-out holds out all rows of a calibration target together.
        var group: Int
        var stage: Stage = .point
    }

    func predict(_ f: [Double]) -> CGPoint? {
        guard f.count > max(designX.cols.max() ?? 0, designY.cols.max() ?? 0) else { return nil }
        let tx = designX(f), ty = designY(f)
        return CGPoint(x: zip(tx, wx).map(*).reduce(0, +), y: zip(ty, wy).map(*).reduce(0, +))
    }

    static func quadOn(_ rows: [Row]) -> Bool {
        Set(rows.filter { $0.stage != .implicit }.map(\.group)).count >= 7
    }

    static func fit(_ rows: [Row], names: [String], spec: GazeModelSpec, lambda: Double) -> GazeRegression? {
        let q = quadOn(rows)
        let feats = rows.map(\.features)
        guard let dx = GazeDesign(terms: spec.x, names: names, rows: feats, quadOn: q),
              let dy = GazeDesign(terms: spec.yTerms, names: names, rows: feats, quadOn: q) else { return nil }
        var gx = Gram(p: dx(feats[0]).count), gy = Gram(p: dy(feats[0]).count)
        for r in rows {
            gx.add(dx(r.features), r.target.x, r.weight)
            gy.add(dy(r.features), r.target.y, r.weight)
        }
        guard let wx = gx.solve(lambda: lambda), let wy = gy.solve(lambda: lambda) else { return nil }
        return GazeRegression(spec: spec, lambda: lambda, designX: dx, designY: dy, wx: wx, wy: wy)
    }

    struct Candidate {
        var spec: String
        var lambda: Double
        /// Leave-one-target-out mean error (points).
        var error: Double
        /// Fit on still frames, predict the move frames (points); nil without move frames.
        var stillToMove: Double?
    }

    struct Selection {
        var model: GazeRegression
        var table: [Candidate]
    }

    /// Per-axis leave-one-target-out predictions for one design and every lambda, via Gram subtraction
    /// (calib.py lopo): the Gram matrices are built once, each fold subtracts its group's share.
    private static func axisCV(design: GazeDesign, rows: [Row], value: (Row) -> Double, groups: [Int],
                               stillIdx: [Int], moveIdx: [Int]) -> [Double: (loo: [Double], s2m: [Int: Double])] {
        let x = rows.map { design($0.features) }
        let p = x[0].count
        var total = Gram(p: p)
        var per: [Int: Gram] = [:]
        var still = Gram(p: p)
        let stillSet = Set(stillIdx)
        for (i, r) in rows.enumerated() {
            total.add(x[i], value(r), r.weight)
            per[r.group, default: Gram(p: p)].add(x[i], value(r), r.weight)
            if stillSet.contains(i) { still.add(x[i], value(r), r.weight) }
        }
        let folds = groups.map { ($0, total.minus(per[$0]!)) }
        var out: [Double: (loo: [Double], s2m: [Int: Double])] = [:]
        for lambda in lambdas {
            var loo = [Double](repeating: .nan, count: rows.count)
            var ok = true
            for (g, gram) in folds {
                guard let w = gram.solve(lambda: lambda) else { ok = false; break }
                for i in rows.indices where rows[i].group == g { loo[i] = zip(x[i], w).map(*).reduce(0, +) }
            }
            guard ok else { continue }
            var s2m: [Int: Double] = [:]
            if !moveIdx.isEmpty, stillIdx.count > p, let w = still.solve(lambda: lambda) {
                for i in moveIdx { s2m[i] = zip(x[i], w).map(*).reduce(0, +) }
            }
            out[lambda] = (loo, s2m)
        }
        return out
    }

    /// Leave-one-target-out CV over spec x lambda. Ties (within 3 %) go to the lower still->move error.
    /// Returns every candidate's scores; `preferred` (e.g. "hybrid") is used when present, else the CV best.
    static func select(_ rows: [Row], names: [String], size: CGSize, preferred: String?) -> Selection? {
        let groups = Array(Set(rows.map(\.group))).sorted()
        guard groups.count >= 4 else { return nil }
        let q = quadOn(rows)
        let feats = rows.map(\.features)
        let stillIdx = rows.indices.filter { rows[$0].stage == .still }
        let moveIdx = rows.indices.filter { rows[$0].stage == .move }
        var table: [Candidate] = []
        for spec in GazeModelSpec.candidates(names: names) {
            guard let dx = GazeDesign(terms: spec.x, names: names, rows: feats, quadOn: q),
                  let dy = GazeDesign(terms: spec.yTerms, names: names, rows: feats, quadOn: q) else { continue }
            let cvx = axisCV(design: dx, rows: rows, value: { Double($0.target.x) }, groups: groups,
                             stillIdx: stillIdx, moveIdx: moveIdx)
            let cvy = axisCV(design: dy, rows: rows, value: { Double($0.target.y) }, groups: groups,
                             stillIdx: stillIdx, moveIdx: moveIdx)
            for lambda in lambdas {
                guard let cx = cvx[lambda], let cy = cvy[lambda] else { continue }
                // mean error per target, then over targets (implicit rows are not scored)
                var perGroup: [Int: (Double, Double)] = [:]
                for i in rows.indices where rows[i].stage != .implicit {
                    let e = hypot((cx.loo[i] - rows[i].target.x) * size.width, (cy.loo[i] - rows[i].target.y) * size.height)
                    perGroup[rows[i].group, default: (0, 0)].0 += e
                    perGroup[rows[i].group, default: (0, 0)].1 += 1
                }
                let errs = perGroup.values.map { $0.0 / $0.1 }
                guard !errs.isEmpty else { continue }
                var s2m: Double?
                let e = moveIdx.compactMap { i -> Double? in
                    guard let px = cx.s2m[i], let py = cy.s2m[i] else { return nil }
                    return hypot((px - rows[i].target.x) * size.width, (py - rows[i].target.y) * size.height)
                }
                if !e.isEmpty { s2m = e.reduce(0, +) / Double(e.count) }
                table.append(Candidate(spec: spec.name, lambda: lambda, error: errs.reduce(0, +) / Double(errs.count),
                                       stillToMove: s2m))
            }
        }
        guard let bestErr = table.map(\.error).min() else { return nil }
        func pick(_ cands: [Candidate]) -> Candidate? {
            guard let best = cands.map(\.error).min() else { return nil }
            let near = cands.filter { $0.error <= best * 1.03 }
            return near.min { ($0.stillToMove ?? $0.error) < ($1.stillToMove ?? $1.error) }
        }
        let preferredRows = table.filter { $0.spec == preferred }
        guard let chosen = pick(preferredRows.isEmpty ? table.filter { $0.error <= bestErr * 1.03 } : preferredRows),
              let spec = GazeModelSpec.candidates(names: names).first(where: { $0.name == chosen.spec }),
              let model = fit(rows, names: names, spec: spec, lambda: chosen.lambda) else { return nil }
        return Selection(model: model, table: table)
    }

    /// Gaussian elimination with partial pivoting.
    static func solve(_ a0: [[Double]], _ b0: [Double]) -> [Double]? {
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
