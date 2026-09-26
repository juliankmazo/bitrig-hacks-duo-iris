import SwiftUI
import Observation
import os
import AVFoundation

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
    enum CalibrationPhase { case settle, sampling, moving, validating }
    private(set) var isValidating = false
    private(set) var validationAccuracy: Double?
    private(set) var validationPerCell: [Int: Double] = [:]
    private(set) var recordingName: String?
    @ObservationIgnored private var recorder: SessionRecorder?
    @ObservationIgnored private var recentFeatures: [[Double]] = []
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
        if s != lastSample {
            sampleCount += 1
            lastSample = s
            if !s.blink, let f = s.featureVector {
                recentFeatures.append(f)
                if recentFeatures.count > 15 { recentFeatures.removeFirst() }
            }
        }
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
        guard let z, now >= cooldownUntil, isSelectable(z) else {
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
            // Implicit recalibration: the dwell is a labelled sample (median of the last ~0.5 s).
            if let layout, let f = Self.median(recentFeatures) {
                calibrator.addImplicit(cell: z, features: f, layout: layout)
            }
            cooldownUntil = now.addingTimeInterval(Self.cooldown)
            dwellZone = nil
            dwellProgress = 0
        }
    }

    // MARK: Typing

    /// Typed text (the reading area).
    private(set) var text = ""
    /// Level 2: the letter-group cell that was zoomed into; nil = level 1.
    private(set) var level2Group: Int?
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()

    /// Speak the typed text (en-US, rate 0.5).
    func speak() {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        synthesizer.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: t)
        u.voice = AVSpeechSynthesisVoice(language: "en-US")
        u.rate = 0.5
        synthesizer.speak(u)
        Self.logger.notice("speak \(t, privacy: .public)")
    }

    /// "Start over" confirmation flash.
    private(set) var startOverFlash = false
    /// Cell the zoom animates from.
    private(set) var zoomOrigin: Int = 5

    var suggestions: [String] { Keyboard.suggestions(for: text) }

    func isSelectable(_ z: Int) -> Bool {
        if let g = level2Group { return Keyboard.key(at: z, group: g) != nil }
        return Self.cells[safe: z]?.isSelectable == true
    }

    /// Label of what selecting cell `z` does at the current level (for the log / flash).
    func select(_ z: Int) {
        guard isSelectable(z) else { return }
        var label: String
        if let g = level2Group, let key = Keyboard.key(at: z, group: g) {
            label = key.label
            withAnimation(.easeOut(duration: 0.25)) {
                if !key.isBack { text += key.label }
                level2Group = nil
            }
        } else if let cell = Self.cells[safe: z] {
            label = cell.logLabel
            switch cell.kind {
            case .letters:
                zoomOrigin = z
                withAnimation(.easeOut(duration: 0.25)) { level2Group = z }
            case .space:
                text += " "
            case .delete:
                if !text.isEmpty { text.removeLast() }
            case .startOver:
                // Clear with a short confirmation flash of the text area (no dialog).
                startOverFlash = true
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(300))
                    self?.startOverFlash = false
                }
                text = ""
            case .suggest:
                let i = [3: 0, 7: 1, 11: 2][z] ?? 0
                guard let word = suggestions[safe: i] else { return }
                label = word
                text = String(text.dropLast(Keyboard.currentWord(in: text).count)) + word + " "
            case .back:
                return
            }
        } else {
            return
        }
        selected = label
        log.append(label)
        if log.count > 40 { log.removeFirst(log.count - 40) }
        flashZone = z
        Self.logger.notice("selected \(label, privacy: .public) text=\(self.text, privacy: .public)")
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            if self?.flashZone == z { self?.flashZone = nil }
        }
    }

    func clearLog() {
        log.removeAll()
        selected = nil
        text = ""
        level2Group = nil
    }

    static func median(_ rows: [[Double]]) -> [Double]? {
        guard let d = rows.first?.count, rows.allSatisfy({ $0.count == d }) else { return nil }
        return (0..<d).map { j in
            let v = rows.map { $0[j] }.sorted()
            return v[v.count / 2]
        }
    }

    // MARK: Calibration

    /// Snake order: consecutive targets are neighbours; each row is contiguous (for the nod check).
    static let calibrationRows = [[0, 1, 2, 3], [7, 6, 5, 4], [8, 9, 10, 11]]
    /// Validation visits the cells in a different order.
    static let validationOrder = [5, 10, 3, 8, 1, 6, 11, 0, 9, 2, 7, 4]
    static let settleSeconds: TimeInterval = 0.5
    static let stillSeconds: TimeInterval = 1.2
    static let moveSeconds: TimeInterval = 1.5
    static let validationSettleSeconds: TimeInterval = 0.8
    static let validationSeconds: TimeInterval = 1.5
    /// Rows must differ in head pitch by at least this much (rad), else "nod more" and redo the row.
    static let minRowPitchStep = 0.015
    static let maxRowRetries = 2

    /// `-calPasses 2` runs the targets twice.
    var calPasses = max(1, min(2, UserDefaults.standard.integer(forKey: "calPasses")))
    /// 4 extra targets near the grid-area corners (own groups 12...15). `-corners NO` disables.
    var includeCorners = UserDefaults.standard.object(forKey: "corners") as? Bool ?? true

    /// Normalized target currently shown (cell centre or corner point).
    private(set) var calibrationTarget: CGPoint?
    /// Live instruction under the target.
    private(set) var calibrationInstruction: String?

    /// Corner targets: 4 % / 6 % inside the grid area's corners (the laptop grid is the top half only).
    func cornerTargets(layout: GridLayout) -> [CGPoint] {
        guard let first = layout.cells.first, let last = layout.cells.last, layout.size.width > 0 else { return [] }
        let area = first.union(last)
        let (w, h) = (layout.size.width, layout.size.height)
        let dx = area.width * 0.04, dy = area.height * 0.06
        return [CGPoint(x: area.minX + dx, y: area.minY + dy), CGPoint(x: area.maxX - dx, y: area.minY + dy),
                CGPoint(x: area.minX + dx, y: area.maxY - dy), CGPoint(x: area.maxX - dx, y: area.maxY - dy)]
            .map { CGPoint(x: $0.x / w, y: $0.y / h) }
    }

    func startCalibration() {
        calibrationTask?.cancel()
        calibrator.clear()
        isCalibrating = true
        showDebug = false
        validationAccuracy = nil
        validationPerCell = [:]
        screen = .calibration
        recorder?.close()
        recorder = SessionRecorder()
        if let recorder {
            recordingName = recorder.url.lastPathComponent
            Self.logger.notice("recording \(recorder.url.path(), privacy: .public)")
            if let layout {
                recorder.write([
                    "type": "session", "backend": backend.rawValue, "passes": calPasses, "corners": includeCorners,
                    "names": FeatureLayout.names(dimension: source.sample.featureVector?.count ?? 2),
                    "size": [layout.size.width, layout.size.height],
                    "cells": layout.cells.map { [$0.minX / layout.size.width, $0.minY / layout.size.height,
                                                 $0.width / layout.size.width, $0.height / layout.size.height] },
                    "corners_xy": cornerTargets(layout: layout).map { [$0.x, $0.y] },
                ])
            }
        }
        calibrationTask = Task { [weak self] in
            guard let self else { return }
            for pass in 0..<self.calPasses {
                var previousRowPitch: Double?
                for row in Self.calibrationRows {
                    var retries = 0
                    while !Task.isCancelled {
                        var rowPitches: [Double] = []
                        for k in row {
                            guard let target = self.layout?.normalizedCenters[safe: k] else { continue }
                            if let p = await self.calibrateTarget(group: k, cell: k, target: target, pass: pass) {
                                rowPitches.append(p)
                            }
                            if Task.isCancelled { return }
                        }
                        // Rows come from head pitch: consecutive rows must be told apart by a nod.
                        let pitch = rowPitches.isEmpty ? nil : rowPitches.sorted()[rowPitches.count / 2]
                        if let pitch, let prev = previousRowPitch, abs(pitch - prev) < Self.minRowPitchStep,
                           retries < Self.maxRowRetries, self.backend != .sim {
                            retries += 1
                            Self.logger.notice("row \(row, privacy: .public) pitch \(pitch, format: .fixed(precision: 3)) vs \(prev, format: .fixed(precision: 3)): nod more")
                            self.calibrationMessage = "Nod more — point your nose at this row"
                            self.calibrator.removeFrames(groups: Set(row), pass: pass)
                            try? await Task.sleep(for: .milliseconds(1200))
                            continue
                        }
                        if let pitch { previousRowPitch = pitch }
                        break
                    }
                }
                if self.includeCorners, let layout = self.layout {
                    for (i, target) in self.cornerTargets(layout: layout).enumerated() {
                        _ = await self.calibrateTarget(group: Self.cornerGroup + i, cell: nil, target: target, pass: pass)
                        if Task.isCancelled { return }
                    }
                }
            }
            guard let layout = self.layout else { return self.finishCalibration() }
            self.calibrationInstruction = "Fitting…"
            self.calibrator.fit(layout: layout)
            self.recorder?.write(["type": "fit", "model": self.calibrator.modelDescription,
                                  "calErr": self.calibrator.residualPoints ?? -1, "cv": self.calibrator.cvPoints ?? -1])
            if self.calibrator.isCalibrated {
                await self.validate(layout: layout)
            }
            self.finishCalibration()
        }
    }

    static let cornerGroup = 12

    /// One target: settle, then a "still" phase (nose on the target) and a "move" phase (gentle nods/turns).
    /// Every usable frame goes into the fit. Returns the median head pitch of the still phase.
    private func calibrateTarget(group: Int, cell: Int?, target: CGPoint, pass: Int) async -> Double? {
        var attempt = 0
        while !Task.isCancelled {
            calibratingZone = cell
            calibrationTarget = target
            simulated.pinnedTourTarget = target
            calibrationPhase = .settle
            calibrationInstruction = "Point your nose at the target"
            await pump(seconds: Self.settleSeconds, phase: "settle", cell: group, pass: pass) { _ in }
            calibrationMessage = nil

            var still: [[Double]] = [], move: [[Double]] = []
            var frames = 0, lost = 0
            calibrationPhase = .sampling
            calibrationInstruction = "Hold still — nose and eyes on the target"
            await pump(seconds: Self.stillSeconds, phase: "still", cell: group, pass: pass) { s in
                frames += 1
                if !s.faceDetected { lost += 1 } else if !s.blink, let f = s.featureVector { still.append(f) }
            }
            calibrationPhase = .moving
            calibrationInstruction = "Nod and turn slightly — keep looking at the target"
            await pump(seconds: Self.moveSeconds, phase: "move", cell: group, pass: pass) { s in
                frames += 1
                if !s.faceDetected { lost += 1 } else if !s.blink, let f = s.featureVector { move.append(f) }
            }
            calibrationPhase = nil
            if Task.isCancelled { return nil }

            let lostTooMuch = frames == 0 || Double(lost) / Double(frames) > 0.3 || still.count < 8
            if lostTooMuch, attempt < 5 {
                attempt += 1
                calibrationMessage = "Face lost — look at the target again"
                Self.logger.notice("target \(group) rejected: face lost \(lost)/\(frames)")
                try? await Task.sleep(for: .milliseconds(600))
                continue
            }
            calibrator.addFrames(still, group: group, target: target, pass: pass, stage: .still)
            calibrator.addFrames(move, group: group, target: target, pass: pass, stage: .move)
            let names = FeatureLayout.names(dimension: still.first?.count ?? 0)
            let pitchIdx = names.firstIndex(of: "pitch")
            let pitch = pitchIdx.flatMap { i in Self.median(still.map { [$0[i]] })?.first }
            Self.logger.notice("target \(group) pass \(pass): \(still.count) still + \(move.count) move frames, pitch \(pitch ?? .nan, format: .fixed(precision: 3)), median \((Self.median(still) ?? []).map { String(format: "%.3f", $0) }.joined(separator: ","), privacy: .public)")
            recorder?.write(["type": "target", "group": group, "cell": cell ?? -1, "target": [target.x, target.y],
                             "pass": pass, "still": still.count, "move": move.count])
            return pitch ?? (backend == .sim ? Double(target.y) : nil)
        }
        return nil
    }

    /// Validate: the 12 cells in another order, 0.8 s settle + 1.5 s scored, no fitting.
    private func validate(layout: GridLayout) async {
        isValidating = true
        defer { isValidating = false }
        var hits = 0, total = 0
        var perCell: [Int: Double] = [:]
        for k in Self.validationOrder {
            guard !Task.isCancelled else { return }
            calibratingZone = k
            calibrationTarget = layout.normalizedCenters[safe: k]
            simulated.pinnedTourTarget = calibrationTarget
            calibrationPhase = .settle
            calibrationInstruction = "Validate: point your nose at the target"
            await pump(seconds: Self.validationSettleSeconds, phase: "vsettle", cell: k, pass: -1) { _ in }
            calibrationPhase = .validating
            var cellHits = 0, cellTotal = 0
            await pump(seconds: Self.validationSeconds, phase: "validate", cell: k, pass: -1) { s in
                guard s.faceDetected, !s.blink, let p = self.calibrator.predict(s, layout: layout) else { return }
                cellTotal += 1
                if layout.zone(forNormalized: p) == k { cellHits += 1 }
            }
            hits += cellHits
            total += cellTotal
            perCell[k] = cellTotal > 0 ? Double(cellHits) / Double(cellTotal) : 0
        }
        calibrationPhase = nil
        validationAccuracy = total > 0 ? Double(hits) / Double(total) : 0
        validationPerCell = perCell
        let per = perCell.keys.sorted().map { "\($0):\(Int((perCell[$0] ?? 0) * 100))" }.joined(separator: " ")
        Self.logger.notice("validation \(Int((self.validationAccuracy ?? 0) * 100))% (\(hits)/\(total)) per cell \(per, privacy: .public)")
        recorder?.write(["type": "validation", "accuracy": validationAccuracy ?? 0, "hits": hits, "total": total,
                         "perCell": Dictionary(uniqueKeysWithValues: perCell.map { (String($0.key), $0.value) })])
    }

    /// Poll the source for `seconds`, recording every new frame and passing it to `handle`.
    private func pump(seconds: TimeInterval, phase: String, cell: Int, pass: Int,
                      handle: (GazeSample) -> Void) async {
        var last: GazeSample?
        let start = Date.now
        while Date.now.timeIntervalSince(start) < seconds, !Task.isCancelled {
            let s = source.sample
            if s != last {
                last = s
                var rec: [String: Any] = ["type": "frame", "t": Date.now.timeIntervalSince1970, "phase": phase,
                                          "cell": cell, "pass": pass, "face": s.faceDetected, "blink": s.blink,
                                          "f": s.featureVector.map { $0 as Any } ?? NSNull()]
                if let raw = s.raw { rec["raw"] = raw.json }
                recorder?.write(rec)
                handle(s)
            }
            calibrationProgress = Date.now.timeIntervalSince(start) / seconds
            try? await Task.sleep(for: .milliseconds(12))
        }
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

    /// Clears the calibration medians and the implicit (dwell) samples.
    func resetCalibration() {
        calibrationTask?.cancel()
        calibrator.clear()
        validationAccuracy = nil
        validationPerCell = [:]
        showDebug = false
        finishCalibration()
    }

    func skipCalibration() { resetCalibration() }

    private func finishCalibration() {
        isCalibrating = false
        isValidating = false
        calibratingZone = nil
        calibrationTarget = nil
        calibrationInstruction = nil
        calibrationProgress = 0
        calibrationPhase = nil
        calibrationMessage = nil
        simulated.pinnedTourTarget = nil
        recorder?.close()
        recorder = nil
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
