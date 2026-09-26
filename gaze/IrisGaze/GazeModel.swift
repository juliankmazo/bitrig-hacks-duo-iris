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
    enum CalibrationPhase { case settle, sampling }
    private(set) var calibrationPhase: CalibrationPhase?
    private(set) var calibrationMessage: String?
    /// Debug overlay: live predicted point + the 12 calibration medians projected through the fit.
    var showDebug = false

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
        calibrator.clear()
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

        let z = calibrator.process(s, layout: layout)
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

    /// Snake order: consecutive targets are neighbours.
    static let calibrationOrder = [0, 1, 2, 3, 7, 6, 5, 4, 8, 9, 10, 11]
    static let settleSeconds: TimeInterval = 1.0
    static let sampleSeconds: TimeInterval = 1.5
    static let maxRetries = 2

    /// Max per-feature std during a fixation before the cell is re-asked.
    private var spreadLimits: [Double] {
        switch backend {
        case .mac: [0.025, 0.045, 0.04, 0.04, .infinity]  // eye_x, eye_y, yaw, pitch, roll
        default: [0.04, 0.04]
        }
    }

    func startCalibration() {
        calibrationTask?.cancel()
        calibrator.clear()
        isCalibrating = true
        showDebug = false
        screen = .calibration
        calibrationTask = Task { [weak self] in
            guard let self else { return }
            for k in Self.calibrationOrder {
                var attempt = 0
                while !Task.isCancelled {
                    self.calibratingZone = k
                    self.simulated.pinnedTourTarget = self.layout?.normalizedCenters[safe: k]
                    let result = await self.collect(zone: k)
                    if Task.isCancelled { return }
                    if let median = result.median, (result.ok || attempt >= Self.maxRetries) {
                        self.calibrator.setMedian(zone: k, median)
                        Self.logger.notice("cal zone \(k) n=\(result.count) ok=\(result.ok) median=\(median.map { String(format: "%.4f", $0) }.joined(separator: ","), privacy: .public) std=\(result.std.map { String(format: "%.4f", $0) }.joined(separator: ","), privacy: .public)")
                        break
                    }
                    attempt += 1
                    if attempt > 5 {   // no usable data at all: skip this cell, fit with the rest
                        Self.logger.notice("cal zone \(k) skipped")
                        break
                    }
                    self.calibrationMessage = result.reason
                    Self.logger.notice("cal zone \(k) rejected: \(result.reason, privacy: .public)")
                    try? await Task.sleep(for: .milliseconds(700))
                }
            }
            if let layout = self.layout { self.calibrator.fit(layout: layout) }
            self.finishCalibration()
            self.showDebug = true   // show the fit right away so the error is visible
        }
    }

    private struct Collection {
        var median: [Double]?
        var std: [Double] = []
        var count = 0
        var ok = false
        var reason = ""
    }

    /// Settle, then sample; median per feature; flag large spread or lost face.
    private func collect(zone k: Int) async -> Collection {
        calibrationPhase = .settle
        let settleStart = Date.now
        while Date.now.timeIntervalSince(settleStart) < Self.settleSeconds, !Task.isCancelled {
            calibrationProgress = Date.now.timeIntervalSince(settleStart) / Self.settleSeconds
            try? await Task.sleep(for: .milliseconds(30))
        }
        calibrationMessage = nil
        calibrationPhase = .sampling
        var samples: [[Double]] = []
        var frames = 0, lost = 0
        var last: GazeSample?
        let start = Date.now
        while Date.now.timeIntervalSince(start) < Self.sampleSeconds, !Task.isCancelled {
            let s = source.sample
            if s != last {
                last = s
                frames += 1
                if !s.faceDetected { lost += 1 }
                else if !s.blink, let f = s.featureVector { samples.append(f) }
            }
            calibrationProgress = Date.now.timeIntervalSince(start) / Self.sampleSeconds
            try? await Task.sleep(for: .milliseconds(15))
        }
        calibrationPhase = nil
        guard samples.count >= 8, let d = samples.first?.count else {
            return Collection(count: samples.count, reason: "Face lost — look at the cell again")
        }
        let median = (0..<d).map { j -> Double in
            let v = samples.map { $0[j] }.sorted()
            return v[v.count / 2]
        }
        let std = (0..<d).map { j -> Double in
            let v = samples.map { $0[j] }
            let m = v.reduce(0, +) / Double(v.count)
            return (v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(v.count)).squareRoot()
        }
        let limits = spreadLimits
        let shaky = zip(std, limits).contains { $0 > $1 }
        let lostTooMuch = frames > 0 && Double(lost) / Double(frames) > 0.3
        var c = Collection(median: median, std: std, count: samples.count, ok: !shaky && !lostTooMuch)
        c.reason = lostTooMuch ? "Face lost — look at the cell again" : "Too shaky — hold your gaze steady"
        return c
    }

    /// "Test": leave calibration and toggle the debug overlay (live predicted point + projected medians).
    func test() {
        if isCalibrating {
            calibrationTask?.cancel()
            finishCalibration()
            showDebug = true
        } else {
            showDebug.toggle()
        }
    }

    func resetCalibration() {
        calibrationTask?.cancel()
        calibrator.clear()
        showDebug = false
        finishCalibration()
    }

    func skipCalibration() { resetCalibration() }

    private func finishCalibration() {
        isCalibrating = false
        calibratingZone = nil
        calibrationProgress = 0
        calibrationPhase = nil
        calibrationMessage = nil
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
