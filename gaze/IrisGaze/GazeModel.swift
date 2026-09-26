import SwiftUI
import Observation
import os

enum Screen: String {
    case idle, calibration, grid
}

/// Pipeline: source sample -> calibrator (EMA, nearest centroid / direct, hysteresis) -> dwell.
@Observable
@MainActor
final class GazeModel {
    static let labels = (0..<12).map { String(UnicodeScalar(UInt8(65 + $0))) } // A...L
    static let dwellDuration: TimeInterval = 1.0
    static let cooldown: TimeInterval = 0.8
    static let logger = Logger(subsystem: "dev.julian.irisgaze", category: "gaze")

    let simulated = SimulatedGazeSource()
    let device = DeviceGazeSource()
    private(set) var source: any GazeSource
    var usingSimulated: Bool { source === simulated }

    let calibrator = GazeCalibrator()

    var screen: Screen = .grid
    var hingeText = "hinge: none"

    private(set) var zone: Int?
    private(set) var dwellProgress: Double = 0
    private(set) var inCooldown = false
    private(set) var selected: String?
    private(set) var log: [String] = []
    /// The cell that just fired, for a flash.
    private(set) var flashZone: Int?

    // Calibration state
    private(set) var calibratingZone: Int?
    private(set) var calibrationProgress: Double = 0
    private(set) var isCalibrating = false

    @ObservationIgnored var layout: GridLayout? {
        didSet {
            simulated.tourPoints = layout?.normalizedCenters ?? []
            if let layout {
                Self.logger.notice("layout size=\(String(describing: layout.size), privacy: .public) foldGap=\(String(describing: layout.foldGap), privacy: .public) cell0=\(String(describing: layout.cells.first), privacy: .public)")
            }
        }
    }
    @ObservationIgnored private var dwellZone: Int?
    @ObservationIgnored private var dwellStart = Date.now
    @ObservationIgnored private var cooldownUntil = Date.distantPast
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var calibrationTask: Task<Void, Never>?

    static let forcedScreen = UserDefaults.standard.string(forKey: "forceScreen").flatMap(Screen.init(rawValue:))

    init() {
        #if targetEnvironment(simulator)
        source = simulated
        #else
        source = device
        #endif
        if let forced = Self.forcedScreen { screen = forced }
        // `-tour YES` starts the demo tour at launch (hands-free recording).
        simulated.tourEnabled = UserDefaults.standard.bool(forKey: "tour")
    }

    func start() {
        source.start()
        guard loop == nil else { return }
        if UserDefaults.standard.bool(forKey: "autoCalibrate") {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))  // wait for first real layout
                self?.startCalibration()
            }
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    func useSimulated(_ on: Bool) {
        let next: any GazeSource = on ? simulated : device
        guard next !== source else { return }
        source.stop()
        source = next
        calibrator.clearCentroids()
        source.start()
    }

    // MARK: Hinge

    func apply(hinge: DeviceHinge?) {
        Self.logger.notice("hinge: \(String(describing: hinge), privacy: .public)")
        if let forced = Self.forcedScreen {
            // Debug/recording override: `-forceScreen grid|calibration|idle` pins the screen.
            hingeText = hinge.map { "\($0.status == .closed ? "closed" : $0.status == .fullyOpen ? "flat" : "book") \(Int($0.angle.degrees))° (pinned)" } ?? "hinge: none"
            screen = forced
            return
        }
        guard let hinge else {
            hingeText = "hinge: none"
            if screen == .idle { screen = .grid }
            return
        }
        let deg = Int(hinge.angle.degrees.rounded())
        if hinge.status == .closed {
            hingeText = "closed \(deg)°"
            screen = .idle
        } else if hinge.status == .fullyOpen {
            hingeText = "flat \(deg)°"
            screen = .calibration
        } else {
            hingeText = "book \(deg)°"
            if !isCalibrating { screen = .grid }
        }
    }

    // MARK: Pipeline

    private func tick() {
        let s = source.sample
        let z = calibrator.process(s.point) { [layout] p in layout?.zone(forNormalized: p) }
        if zone != z { zone = z }
        guard screen == .grid else {
            dwellProgress = 0
            dwellZone = nil
            return
        }
        let now = Date.now
        inCooldown = now < cooldownUntil
        guard let z, !inCooldown else {
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
        guard Self.labels.indices.contains(z) else { return }
        selected = Self.labels[z]
        log.append(Self.labels[z])
        if log.count > 40 { log.removeFirst(log.count - 40) }
        flashZone = z
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
                try? await Task.sleep(for: .milliseconds(500))
                var samples: [CGPoint] = []
                let started = Date.now
                // ~30 samples over ~1.5 s (20 Hz); give up after 3 s if the face is lost.
                while samples.count < 30, Date.now.timeIntervalSince(started) < 3, !Task.isCancelled {
                    if let p = self.source.sample.point { samples.append(p) }
                    self.calibrationProgress = Double(samples.count) / 30
                    try? await Task.sleep(for: .milliseconds(50))
                }
                self.calibrator.setCentroid(zone: k, samples: samples)
            }
            self.finishCalibration()
        }
    }

    func skipCalibration() {
        calibrationTask?.cancel()
        calibrator.clearCentroids()
        finishCalibration()
    }

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
