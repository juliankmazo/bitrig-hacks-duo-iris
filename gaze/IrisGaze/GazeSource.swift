import CoreGraphics

/// One gaze reading. `point` is normalized 0...1 in the app's inner-display view space
/// (for uncalibrated device backends it is a raw feature; calibration maps it to zones).
struct GazeSample: Equatable {
    var point: CGPoint?
    var blink: Bool = false
    var faceDetected: Bool = false

    static let none = GazeSample(point: nil)
}

/// A swappable gaze backend. Conformers are `@Observable`.
@MainActor
protocol GazeSource: AnyObject {
    var name: String { get }
    var sample: GazeSample { get }
    func start()
    func stop()
}
