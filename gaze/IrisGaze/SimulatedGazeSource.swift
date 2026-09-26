import CoreGraphics
import Foundation
import Observation

/// Gaze that follows a finger (drag) or auto-walks the grid ("demo tour").
/// Adds jitter so smoothing and hysteresis are exercised.
@Observable
@MainActor
final class SimulatedGazeSource: GazeSource {
    let name = "Simulated"
    private(set) var sample = GazeSample.none

    /// Where the finger last was (normalized). Stays put when the finger lifts.
    var fingerTarget: CGPoint?
    /// Demo tour on/off.
    var tourEnabled = false { didSet { tourStart = .now } }
    /// Tour stops, normalized (set from the grid layout).
    var tourPoints: [CGPoint] = []
    /// When non-nil, the tour follows this point instead (calibration dot).
    var pinnedTourTarget: CGPoint?
    var tourDwell: TimeInterval = 1.3
    var jitter: CGFloat = 0.012

    private var current: CGPoint?
    private var tourStart = Date.now
    private var loop: Task<Void, Never>?

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.step()
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        sample = .none
    }

    private func tourTarget() -> CGPoint? {
        if let pinnedTourTarget { return pinnedTourTarget }
        guard !tourPoints.isEmpty else { return nil }
        let i = Int(Date.now.timeIntervalSince(tourStart) / tourDwell) % tourPoints.count
        return tourPoints[i]
    }

    private func step() {
        let target = tourEnabled ? tourTarget() : fingerTarget
        guard let target else {
            current = nil
            sample = GazeSample(point: nil, blink: false, faceDetected: false)
            return
        }
        // Eye-like saccade: fast exponential approach.
        if let c = current {
            let k: CGFloat = 0.35
            current = CGPoint(x: c.x + (target.x - c.x) * k, y: c.y + (target.y - c.y) * k)
        } else {
            current = target
        }
        let noisy = CGPoint(
            x: current!.x + CGFloat.random(in: -jitter...jitter),
            y: current!.y + CGFloat.random(in: -jitter...jitter)
        )
        sample = GazeSample(point: noisy, blink: false, faceDetected: true)
    }
}
