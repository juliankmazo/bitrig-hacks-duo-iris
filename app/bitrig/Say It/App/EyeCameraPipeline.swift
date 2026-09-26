import AVFoundation
import Foundation
import ImageIO
import Vision

final class EyeCameraPipeline: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
  var onFeature: ((CGPoint?) -> Void)?

  private var session = AVCaptureSession()
  private var queue = DispatchQueue(label: "SayIt.EyeCamera")
  private var isConfigured = false
  private var isLandscape = false
  private var frameNumber = 0
  private var orientationIndex = 0
  private var missingFaceFrames = 0
  private var gazeProcessingEnabled = true

  func start() async -> Bool {
    await withCheckedContinuation { continuation in
      queue.async {
        if !self.isConfigured && !self.configure() {
          continuation.resume(returning: false)
          return
        }
        if !self.session.isRunning {
          self.session.startRunning()
        }
        continuation.resume(returning: self.session.isRunning)
      }
    }
  }

  func stop() {
    queue.async {
      if self.session.isRunning {
        self.session.stopRunning()
      }
    }
  }

  func setLandscape(_ value: Bool) {
    queue.async {
      if self.isLandscape != value {
        self.isLandscape = value
        self.orientationIndex = 0
        self.missingFaceFrames = 0
      }
    }
  }

  func setGazeProcessingEnabled(_ value: Bool) {
    queue.async { self.gazeProcessingEnabled = value }
  }

  private func configure() -> Bool {
    guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
      ?? AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .front),
      let input = try? AVCaptureDeviceInput(device: device) else { return false }

    let output = AVCaptureVideoDataOutput()
    output.alwaysDiscardsLateVideoFrames = true

    session.beginConfiguration()
    session.sessionPreset = .high
    guard session.canAddInput(input), session.canAddOutput(output) else {
      session.commitConfiguration()
      return false
    }
    session.addInput(input)
    session.addOutput(output)
    output.setSampleBufferDelegate(self, queue: queue)
    session.commitConfiguration()
    isConfigured = true
    return true
  }

  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    guard gazeProcessingEnabled else { return }
    frameNumber += 1
    guard frameNumber.isMultiple(of: 3) else { return }

    let orientations: [CGImagePropertyOrientation] = isLandscape
      ? [.upMirrored, .downMirrored, .leftMirrored, .rightMirrored]
      : [.leftMirrored, .rightMirrored, .upMirrored, .downMirrored]
    let orientation = orientations[orientationIndex]
    let request = VNDetectFaceLandmarksRequest()
    let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: orientation)
    guard (try? handler.perform([request])) != nil,
          let face = request.results?.first,
          let landmarks = face.landmarks else {
      missingFaceFrames += 1
      if missingFaceFrames >= 8 {
        orientationIndex = (orientationIndex + 1) % orientations.count
        missingFaceFrames = 0
      }
      onFeature?(nil)
      return
    }
    missingFaceFrames = 0

    let left = pupilPosition(pupil: landmarks.leftPupil, eye: landmarks.leftEye)
    let right = pupilPosition(pupil: landmarks.rightPupil, eye: landmarks.rightEye)
    if let left, let right {
      onFeature?(CGPoint(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2))
    } else {
      onFeature?(left ?? right)
    }
  }

  private func pupilPosition(pupil: VNFaceLandmarkRegion2D?, eye: VNFaceLandmarkRegion2D?) -> CGPoint? {
    guard let pupil = pupil?.normalizedPoints.first,
          let points = eye?.normalizedPoints,
          !points.isEmpty else { return nil }

    let minX = points.map(\.x).min() ?? 0
    let maxX = points.map(\.x).max() ?? 0
    let minY = points.map(\.y).min() ?? 0
    let maxY = points.map(\.y).max() ?? 0
    guard maxX - minX > 0, maxY - minY > 0 else { return nil }

    return CGPoint(
      x: (pupil.x - minX) / (maxX - minX),
      y: (pupil.y - minY) / (maxY - minY)
    )
  }
}
