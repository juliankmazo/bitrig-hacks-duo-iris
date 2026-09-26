import CoreGraphics

/// One gaze reading.
/// - `point`: normalized 0...1 in the app's view space (sim), or a rough raw point (device backends).
/// - `features`: optional raw feature vector (Mac: [eye_x, eye_y, yaw, pitch, roll]); calibration
///   regresses these to the screen. When nil, `point` is the feature.
struct GazeSample: Equatable {
    var point: CGPoint?
    var features: [Double]? = nil
    var blink: Bool = false
    var faceDetected: Bool = false

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
