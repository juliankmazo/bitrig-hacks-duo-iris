import CoreGraphics
import Foundation
import Observation

/// Gaze streamed from the Mac webcam (`gaze/mac/gaze_server.py`) over ws://127.0.0.1:8777.
/// The raw feature (-1...1) is not screen aligned, so this backend needs calibration.
@Observable
@MainActor
final class MacGazeSource: GazeSource {
    let name = "Mac webcam"
    private(set) var sample = GazeSample.none
    private(set) var isConnected = false

    @ObservationIgnored private let url: URL
    @ObservationIgnored private var task: URLSessionWebSocketTask?
    @ObservationIgnored private var loop: Task<Void, Never>?

    init(url: URL = URL(string: "ws://127.0.0.1:8777")!) {
        self.url = url
    }

    private struct Message: Decodable {
        let type: String
        let x: Double
        let y: Double
        let blink: Bool
        let face: Bool
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runConnection()
                // Auto-reconnect every 1 s.
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isConnected = false
        sample = .none
    }

    private func runConnection() async {
        let task = URLSession.shared.webSocketTask(with: url)
        self.task = task
        task.resume()
        defer {
            task.cancel(with: .goingAway, reason: nil)
            isConnected = false
            sample = .none
        }
        let decoder = JSONDecoder()
        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do { message = try await task.receive() } catch { return }
            let data: Data?
            switch message {
            case .string(let s): data = s.data(using: .utf8)
            case .data(let d): data = d
            @unknown default: data = nil
            }
            guard let data, let m = try? decoder.decode(Message.self, from: data), m.type == "gaze" else { continue }
            isConnected = true
            sample = GazeSample(
                point: m.face ? CGPoint(x: (m.x + 1) / 2, y: (m.y + 1) / 2) : nil,
                blink: m.blink,
                faceDetected: m.face
            )
        }
    }
}
