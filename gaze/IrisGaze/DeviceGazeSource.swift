import CoreGraphics
import Foundation
import Observation

#if !targetEnvironment(simulator)
import ARKit
import AVFoundation
import Vision

/// Real on-device gaze.
/// 1. ARKit face tracking (`lookAtPoint` ray intersected with the camera plane) when supported.
/// 2. Otherwise AVCapture front camera (virtual front camera on Duo) + Vision pupil landmarks.
/// Output points are raw features in roughly 0...1; calibration maps them to zones.
@Observable
@MainActor
final class DeviceGazeSource: NSObject, GazeSource {
    private(set) var name = "Device"
    private(set) var sample = GazeSample.none

    @ObservationIgnored private var arSession: ARSession?
    @ObservationIgnored private var visionPipeline: VisionGazePipeline?

    func start() {
        if ARFaceTrackingConfiguration.isSupported {
            name = "ARKit face"
            let session = ARSession()
            session.delegate = self   // delegate queue nil = main queue
            let config = ARFaceTrackingConfiguration()
            config.isLightEstimationEnabled = false
            session.run(config, options: [.resetTracking, .removeExistingAnchors])
            arSession = session
        } else {
            name = "Vision pupils"
            let pipeline = VisionGazePipeline { [weak self] sample in
                Task { @MainActor in self?.sample = sample }
            }
            visionPipeline = pipeline
            AVCaptureDevice.requestAccess(for: .video) { granted in
                guard granted else { return }
                pipeline.start()
            }
        }
    }

    func stop() {
        arSession?.pause()
        arSession = nil
        visionPipeline?.stop()
        visionPipeline = nil
        sample = .none
    }

    fileprivate func update(anchor: ARFaceAnchor, camera: ARCamera) {
        guard anchor.isTracked else {
            sample = GazeSample(point: nil, blink: false, faceDetected: false)
            return
        }
        // Face origin and look-at point, in camera space.
        let camInv = camera.transform.inverse
        let face = anchor.transform
        let origin = camInv * face * SIMD4<Float>(0, 0, 0, 1)
        let look = camInv * face * SIMD4<Float>(anchor.lookAtPoint, 1)
        let dir = look - origin
        var point: CGPoint?
        if abs(dir.z) > 1e-5 {
            // Intersect the gaze ray with the device plane (camera z = 0).
            let t = -origin.z / dir.z
            let hit = origin + t * dir
            // Meters -> rough normalized screen. Camera space is sensor-oriented;
            // calibration (nearest centroid) absorbs rotation/offset/scale.
            let screenW: Float = 0.16, screenH: Float = 0.11
            point = CGPoint(x: CGFloat(0.5 + hit.x / screenW), y: CGFloat(0.5 - hit.y / screenH))
        }
        let bl = anchor.blendShapes[.eyeBlinkLeft]?.floatValue ?? 0
        let br = anchor.blendShapes[.eyeBlinkRight]?.floatValue ?? 0
        sample = GazeSample(point: point, blink: bl > 0.6 && br > 0.6, faceDetected: true)
    }
}

extension DeviceGazeSource: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        MainActor.assumeIsolated {
            guard let face = anchors.compactMap({ $0 as? ARFaceAnchor }).first,
                  let camera = session.currentFrame?.camera else { return }
            update(anchor: face, camera: camera)
        }
    }

    nonisolated func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        MainActor.assumeIsolated {
            sample = GazeSample(point: nil, blink: false, faceDetected: false)
        }
    }
}

/// AVCapture + Vision fallback. Runs on its own queue and reports samples via `onSample`.
final class VisionGazePipeline: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "dev.julian.irisgaze.vision")
    private let onSample: @Sendable (GazeSample) -> Void
    private var configured = false

    init(onSample: @escaping @Sendable (GazeSample) -> Void) {
        self.onSample = onSample
    }

    func start() {
        queue.async { [self] in
            if !configured { configure() }
            session.startRunning()
        }
    }

    func stop() {
        queue.async { [self] in session.stopRunning() }
    }

    private func configure() {
        // On iPhone Duo `.front` resolves to the virtual front camera (inner when open, outer when closed).
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTrueDepthCamera],
            mediaType: .video, position: .front)
        guard let device = discovery.devices.first,
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        if session.canAddInput(input) { session.addInput(input) }
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        if let conn = output.connection(with: .video) {
            if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
            if conn.isVideoMirroringSupported {
                conn.automaticallyAdjustsVideoMirroring = false
                conn.isVideoMirrored = true
            }
        }
        session.commitConfiguration()
        configured = true
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        try? handler.perform([request])
        guard let face = request.results?.first, let lm = face.landmarks else {
            onSample(GazeSample(point: nil, blink: false, faceDetected: false))
            return
        }
        var offsets: [CGPoint] = []
        var ears: [CGFloat] = []
        for (eye, pupil) in [(lm.leftEye, lm.leftPupil), (lm.rightEye, lm.rightPupil)] {
            guard let eye, eye.pointCount > 0 else { continue }
            let pts = eye.normalizedPoints
            let minX = pts.map(\.x).min()!, maxX = pts.map(\.x).max()!
            let minY = pts.map(\.y).min()!, maxY = pts.map(\.y).max()!
            let w = max(maxX - minX, 1e-4), h = maxY - minY
            ears.append(h / w)
            if let pupil, let p = pupil.normalizedPoints.first {
                // Pupil offset within the eye box, -0.5...0.5.
                offsets.append(CGPoint(x: (p.x - minX) / w - 0.5, y: (p.y - minY) / max(h, 1e-4) - 0.5))
            }
        }
        let blink = !ears.isEmpty && ears.reduce(0, +) / CGFloat(ears.count) < 0.18
        var point: CGPoint?
        if !offsets.isEmpty {
            let ox = offsets.map(\.x).reduce(0, +) / CGFloat(offsets.count)
            let oy = offsets.map(\.y).reduce(0, +) / CGFloat(offsets.count)
            // Raw gain; Vision's y is up, screen y is down. Calibration does the real mapping.
            point = CGPoint(x: 0.5 + ox * 2.5, y: 0.5 - oy * 2.5)
        }
        onSample(GazeSample(point: point, blink: blink, faceDetected: true))
    }
}

#else

/// Simulator stub: no camera, so the device backend never starts a capture path here.
@Observable
@MainActor
final class DeviceGazeSource: GazeSource {
    let name = "Device (no camera in sim)"
    private(set) var sample = GazeSample.none
    func start() {}
    func stop() {}
}

#endif
