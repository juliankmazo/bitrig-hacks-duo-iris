import SwiftUI
import Observation
import os

enum Screen: String {
    case idle, calibration, grid
}

enum Backend: String, CaseIterable {
    case sim, mac, device

    var title: String {
        switch self {
        case .sim: "Sim"
        case .mac: "Mac"
        case .device: "Device"
        }
    }
}

/// Pipeline: source sample -> calibrator (EMA, nearest centroid / direct, hysteresis) -> dwell.
@Observable
@MainActor
final class GazeModel {
    static let cells = GridCell.all
    static let dwellDuration: TimeInterval = 1.0
    static let cooldown: TimeInterval = 0.8
    static let settle: Duration = .milliseconds(700)
    static let logger = Logger(subsystem: "dev.julian.irisgaze", category: "gaze")
    static let forcedScreen = UserDefaults.standard.string(forKey: "forceScreen").flatMap(Screen.init(rawValue:))
    static let launchBackend = UserDefaults.standard.string(forKey: "backend").flatMap(Backend.init(rawValue:))

    let simulated = SimulatedGazeSource()
    let mac = MacGazeSource()
    let device = DeviceGazeSource()
    private(set) var backend: Backend = .sim
    var source: any GazeSource {
        switch backend {
        case .sim: simulated
        case .mac: mac
        case .device: device
        }
    }
    var usingSimulated: Bool { backend == .sim }
    /// Raw-feature backends are not screen aligned: they need calibration.
    var needsCalibration: Bool { backend != .sim && !calibrator.isCalibrated }

    let calibrator = GazeCalibrator()

    var screen: Screen = .grid
    var hingeText = "hinge: none"

    private(set) var zone: Int?
    private(set) var dwellProgress: Double = 0
    private(set) var selected: String?
    private(set) var log: [String] = []
    private(set) var flashZone: Int?
    private(set) var fps: Int = 0

    // Calibration state
    private(set) var calibratingZone: Int?
    private(set) var calibrationProgress: Double = 0
    private(set) var isCalibrating = false

    @ObservationIgnored var layout: GridLayout? {
        didSet { simulated.tourPoints = layout?.normalizedCenters ?? [] }
    }
    @ObservationIgnored private var dwellZone: Int?
    @ObservationIgnored private var dwellStart = Date.now
    @ObservationIgnored private var cooldownUntil = Date.distantPast
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var calibrationTask: Task<Void, Never>?
    @ObservationIgnored private var lastSample = GazeSample.none
    @ObservationIgnored private var sampleCount = 0
    @ObservationIgnored private var fpsWindowStart = Date.now

    init() {
        if let forced = Self.forcedScreen { screen = forced }
        // `-tour YES` starts the demo tour at launch (hands-free recording).
        simulated.tourEnabled = UserDefaults.standard.bool(forKey: "tour")
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
        Task { [weak self] in
            await self?.chooseInitialBackend()
            if UserDefaults.standard.bool(forKey: "autoCalibrate") {
                try? await Task.sleep(for: .milliseconds(300))
                self?.startCalibration()
            }
        }
    }

    /// `-backend mac|sim|device`; default: Mac if its websocket connects within 2 s, else sim (device on hardware).
    private func chooseInitialBackend() async {
        if let forced = Self.launchBackend {
            setBackend(forced)
            return
        }
        setBackend(.mac)
        for _ in 0..<20 where !mac.isConnected {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if !mac.isConnected {
            #if targetEnvironment(simulator)
            setBackend(.sim)
            #else
            setBackend(.device)
            #endif
        }
        Self.logger.notice("backend: \(self.backend.rawValue, privacy: .public)")
    }

    func setBackend(_ next: Backend) {
        if isStarted, next == backend { return }
        source.stop()
        backend = next
        calibrator.clearCentroids()
        source.start()
        isStarted = true
    }
    @ObservationIgnored private var isStarted = false

    /// Status-tile button: Sim -> Mac (-> Device on hardware) -> Sim.
    func cycleBackend() {
        #if targetEnvironment(simulator)
        let order: [Backend] = [.sim, .mac]
        #else
        let order: [Backend] = [.sim, .mac, .device]
        #endif
        let i = order.firstIndex(of: backend) ?? 0
        setBackend(order[(i + 1) % order.count])
    }

    // MARK: Hinge

    func apply(hinge: DeviceHinge?) {
        Self.logger.notice("hinge: \(String(describing: hinge), privacy: .public)")
        if let forced = Self.forcedScreen {
            // Debug/recording override: `-forceScreen grid|calibration|idle` pins the screen.
            hingeText = hinge.map { "\(Self.statusName($0)) \(Int($0.angle.degrees))° (pinned)" } ?? "hinge: none"
            screen = forced
            return
        }
        guard let hinge else {
            hingeText = "hinge: none"
            if screen == .idle { screen = .grid }
            return
        }
        hingeText = "\(Self.statusName(hinge)) \(Int(hinge.angle.degrees.rounded()))°"
        if hinge.status == .closed {
            screen = .idle
        } else if hinge.status == .fullyOpen {
            screen = .calibration
        } else if !isCalibrating {
            screen = .grid
        }
    }

    private static func statusName(_ h: DeviceHinge) -> String {
        h.status == .closed ? "closed" : h.status == .fullyOpen ? "flat" : "folded"
    }

    // MARK: Pipeline

    private func tick() {
        let s = source.sample
        let now = Date.now
        if s != lastSample { sampleCount += 1; lastSample = s }
        if now.timeIntervalSince(fpsWindowStart) >= 1 {
            fps = sampleCount
            sampleCount = 0
            fpsWindowStart = now
        }

        let z = calibrator.process(s.point) { [layout] p in layout?.zone(forNormalized: p) }
        if zone != z { zone = z }
        guard screen == .grid, !needsCalibration else {
            dwellProgress = 0
            dwellZone = nil
            return
        }
        guard let z, now >= cooldownUntil, Self.cells[safe: z]?.isSelectable == true else {
            dwellZone = nil
            if dwellProgress != 0 { dwellProgress = 0 }
            return
        }
        if z != dwellZone {
            dwellZone = z
            dwellStart = now
        }
        dwellProgress = min(1, now.timeIntervalSince(dwellStart) / Self.dwellDuration)
        if dwellProgress >= 1 {
            select(z)
            cooldownUntil = now.addingTimeInterval(Self.cooldown)
            dwellZone = nil
            dwellProgress = 0
        }
    }

    func select(_ z: Int) {
        guard let cell = Self.cells[safe: z], cell.isSelectable else { return }
        selected = cell.logLabel
        log.append(cell.logLabel)
        if log.count > 40 { log.removeFirst(log.count - 40) }
        flashZone = z
        Self.logger.notice("selected \(cell.logLabel, privacy: .public)")
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            if self?.flashZone == z { self?.flashZone = nil }
        }
    }

    func clearLog() {
        log.removeAll()
        selected = nil
    }

    // MARK: Calibration

    func startCalibration() {
        calibrationTask?.cancel()
        calibrator.clearCentroids()
        isCalibrating = true
        screen = .calibration
        calibrationTask = Task { [weak self] in
            guard let self else { return }
            for k in 0..<GazeCalibrator.zoneCount {
                guard !Task.isCancelled else { return }
                self.calibratingZone = k
                self.calibrationProgress = 0
                self.simulated.pinnedTourTarget = self.layout?.normalizedCenters[safe: k]
                // Settle: let the eyes land on the dot.
                try? await Task.sleep(for: Self.settle)
                var samples: [CGPoint] = []
                let started = Date.now
                // ~30 samples over ~1.5 s (20 Hz); give up after 3 s if the face is lost.
                while samples.count < 30, Date.now.timeIntervalSince(started) < 3, !Task.isCancelled {
                    if let p = self.source.sample.point { samples.append(p) }
                    self.calibrationProgress = Double(samples.count) / 30
                    try? await Task.sleep(for: .milliseconds(50))
                }
                self.calibrator.setCentroid(zone: k, samples: samples)
                Self.logger.notice("cal zone \(k) n=\(samples.count)")
            }
            self.finishCalibration()
        }
    }

    /// "Test": leave calibration and go try the grid.
    func test() {
        calibrationTask?.cancel()
        finishCalibration()
    }

    func resetCalibration() {
        calibrationTask?.cancel()
        calibrator.clearCentroids()
        finishCalibration()
    }

    func skipCalibration() { resetCalibration() }

    private func finishCalibration() {
        isCalibrating = false
        calibratingZone = nil
        calibrationProgress = 0
        simulated.pinnedTourTarget = nil
        screen = .grid
    }

    // MARK: Simulated input

    func fingerMoved(to location: CGPoint) {
        guard let size = layout?.size, size.width > 0, size.height > 0 else { return }
        simulated.fingerTarget = CGPoint(x: location.x / size.width, y: location.y / size.height)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
