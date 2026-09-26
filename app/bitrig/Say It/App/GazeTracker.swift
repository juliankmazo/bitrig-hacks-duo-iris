import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class GazeTracker {
  var phase: GazePhase = .inactive
  var gazePoint: CGPoint?
  var faceVisible = false
  var calibrationStep = 0
  var outerDisplayAvailable = false
  var outerDisplayPresented = false

  @ObservationIgnored private var camera = EyeCameraPipeline()
  @ObservationIgnored private var recentFeatures: [(Date, CGPoint)] = []
  @ObservationIgnored private var calibrationFeatures: [CGPoint] = []
  @ObservationIgnored private var horizontalRange: (CGFloat, CGFloat)?
  @ObservationIgnored private var verticalRange: (CGFloat, CGFloat)?
  @ObservationIgnored private var startID = UUID()
  @ObservationIgnored private var tapSimulationRequested = false

  init() {
    camera.onFeature = { [weak self] feature in
      Task { @MainActor in
        self?.receive(feature)
      }
    }
  }

  func start() async {
    tapSimulationRequested = false
    if phase == .projectionOnly {
      camera.setGazeProcessingEnabled(true)
      resetCalibration()
      return
    }
    await startCamera()
  }

  func startProjection() async {
    tapSimulationRequested = true
    await startCamera()
  }

  func enterTapSimulation() {
    tapSimulationRequested = true
    guard phase == .ready || phase == .calibrating else { return }
    camera.setGazeProcessingEnabled(false)
    gazePoint = nil
    phase = .projectionOnly
  }

  func leaveTapSimulation() {
    tapSimulationRequested = false
    guard phase == .projectionOnly else { return }
    camera.setGazeProcessingEnabled(true)
    resetCalibration()
  }

  private func startCamera() async {
    guard phase == .inactive else { return }
    let requestID = UUID()
    startID = requestID
    phase = .starting

    guard await AVCaptureDevice.requestAccess(for: .video) else {
      guard startID == requestID else { return }
      phase = .failed("Camera access is needed for eye control. You can still use the regular keyboard.")
      return
    }

    let isRunning = await camera.start()
    guard startID == requestID else {
      camera.stop()
      return
    }
    guard isRunning else {
      phase = .failed("The front camera is unavailable. Close other camera apps and try again.")
      return
    }

    if tapSimulationRequested {
      camera.setGazeProcessingEnabled(false)
      phase = .projectionOnly
    } else {
      camera.setGazeProcessingEnabled(true)
      resetCalibration()
    }
  }

  func stop() {
    startID = UUID()
    tapSimulationRequested = false
    camera.stop()
    phase = .inactive
    gazePoint = nil
    faceVisible = false
    outerDisplayAvailable = false
    outerDisplayPresented = false
  }

  func setLandscape(_ isLandscape: Bool) {
    camera.setLandscape(isLandscape)
  }

  func resetCalibration() {
    calibrationStep = 0
    calibrationFeatures = []
    recentFeatures = []
    gazePoint = nil
    faceVisible = false
    horizontalRange = nil
    verticalRange = nil
    phase = .calibrating
  }

  @discardableResult
  func captureCalibrationPoint() -> Bool {
    guard phase == .calibrating else { return false }
    let cutoff = Date().addingTimeInterval(-0.8)
    let samples = recentFeatures.filter { $0.0 >= cutoff }.map(\.1)
    guard samples.count >= 3 else { return false }

    let count = CGFloat(samples.count)
    let mean = CGPoint(
      x: samples.reduce(0) { $0 + $1.x } / count,
      y: samples.reduce(0) { $0 + $1.y } / count
    )
    calibrationFeatures.append(mean)
    calibrationStep += 1

    if calibrationStep == 5 {
      let left = (calibrationFeatures[0].x + calibrationFeatures[3].x) / 2
      let right = (calibrationFeatures[1].x + calibrationFeatures[4].x) / 2
      let top = (calibrationFeatures[0].y + calibrationFeatures[1].y) / 2
      let bottom = (calibrationFeatures[3].y + calibrationFeatures[4].y) / 2

      guard abs(right - left) > 0.01, abs(bottom - top) > 0.01 else {
        phase = .failed("Calibration could not detect enough eye movement. Adjust the phone position and try again.")
        return true
      }
      horizontalRange = (left, right)
      verticalRange = (top, bottom)
      phase = .ready
    }
    return true
  }

  private func receive(_ feature: CGPoint?) {
    guard phase == .calibrating || phase == .ready else { return }
    guard let feature else {
      faceVisible = false
      gazePoint = nil
      return
    }
    faceVisible = true

    let now = Date()
    recentFeatures.append((now, feature))
    recentFeatures.removeAll { now.timeIntervalSince($0.0) > 1.2 }

    guard phase == .ready,
          let horizontalRange,
          let verticalRange else { return }

    let horizontal = 0.15 + 0.70 * (feature.x - horizontalRange.0) / (horizontalRange.1 - horizontalRange.0)
    let vertical = 0.15 + 0.70 * (feature.y - verticalRange.0) / (verticalRange.1 - verticalRange.0)
    let measured = CGPoint(x: min(max(horizontal, 0), 1), y: min(max(vertical, 0), 1))

    if let gazePoint {
      self.gazePoint = CGPoint(
        x: gazePoint.x * 0.65 + measured.x * 0.35,
        y: gazePoint.y * 0.65 + measured.y * 0.35
      )
    } else {
      gazePoint = measured
    }
  }
}

enum GazePhase: Equatable {
  case inactive
  case starting
  case calibrating
  case ready
  case projectionOnly
  case failed(String)
}
