import CoreGraphics

/// Raw per-frame data from the Mac server, kept only so recordings can be re-featurized offline
/// (`replay.py --recompute`): key landmarks (normalized x, y, z), head matrix, eye blendshapes, frame size.
struct RawFrame: Equatable {
    var key: [Double]
    var matrix: [Double]
    var blend: [Double]
    var size: [Double]

    var json: [String: Any] { ["key": key, "m": matrix, "bs": blend, "wh": size] }
}

/// One gaze reading.
/// - `point`: normalized 0...1 in the app's view space (sim), or a rough raw point (device backends).
/// - `features`: optional raw feature vector (Mac, see `FeatureLayout`); calibration regresses these to the
///   screen. When nil, `point` is the feature.
struct GazeSample: Equatable {
    var point: CGPoint?
    var features: [Double]? = nil
    var blink: Bool = false
    var faceDetected: Bool = false
    var raw: RawFrame? = nil

    static let none = GazeSample(point: nil)

    /// The vector calibration and regression work on.
    var featureVector: [Double]? {
        if let features { return features }
        return point.map { [Double($0.x), Double($0.y)] }
    }
}

/// A swappable gaze backend. Conformers are `@Observable`.
@MainActor
protocol GazeSource: AnyObject {
    var name: String { get }
    var sample: GazeSample { get }
    func start()
    func stop()
}
