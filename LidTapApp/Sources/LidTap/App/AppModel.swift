import AppKit
import Observation
import ServiceManagement
import SwiftUI

/// What happened to one detected tap.
struct TapRecord: Identifiable, Equatable {
    enum Outcome: Equatable { case acted, rejected, ignored, recorded, guarded, untrained }

    let id: Int
    let date: Date
    let outcome: Outcome
    let label: String?
    let confidence: Double?
    let detail: String
    let peakG: Double
    let peakA: Double
    let lid: Int?
    let gyro: [[Double]]

    static func == (a: TapRecord, b: TapRecord) -> Bool { a.id == b.id }
}

struct SensorStatus: Equatable {
    var rate: Double = 0
    var lid: Int?
    var noise: Double = 0
    var threshold: Double = 0
    var error: String?
    var accessibility = false
}

struct CalibrationState: Equatable {
    enum Phase: Equatable { case taps, noisePrompt, noise(until: Date), training, done }
    enum Flash: Equatable { case recorded(String), ignored(String) }

    var grid: Grid
    var perZone: Int
    var sequence: [String]
    var position = 0
    var phase: Phase = .taps
    var flash: Flash?
    var flashID = 0
    /// Strength of the most recent tap during calibration (deg/s), for the coaching meter.
    var lastStrength: Double?
    var strengthID = 0

    var target: String? { phase == .taps && position < sequence.count ? sequence[position] : nil }
    var remainingInBlock: Int {
        guard let t = target else { return 0 }
        return sequence[position...].prefix { $0 == t }.count
    }
}

@MainActor @Observable
final class AppModel {
    static let shared = AppModel(store: Store(), presentsUI: true)
    /// Taps stronger than this get a "gentler is fine" hint: there's never a need to press hard on a display.
    static let gentlerAbove = 30.0

    var config: AppConfig {
        didSet {
            guard config != oldValue else { return }
            store.save(config)
            detector.settings = config.detector
            privacyGuard.muteMic = config.guardMutesMic
            privacyGuard.stopCamera = config.guardStopsCamera
            if config.modelChoice != oldValue.modelChoice || config.rejectFactor != oldValue.rejectFactor { refitActiveModel() }
            if config.minTapStrength != oldValue.minTapStrength { scheduleRetrain() }
        }
    }

    private(set) var dataset: Dataset
    private(set) var report: ModelReport?
    private(set) var activeKind: ModelKind?
    private(set) var isTraining = false
    private(set) var recent: [TapRecord] = []
    private(set) var status = SensorStatus()
    var calibration: CalibrationState?
    private(set) var tapFlash = false
    /// The zone that last answered a tap, with a counter so the same zone can ripple again.
    private(set) var ripple: (zone: Int, id: Int)?
    /// Zone the Settings window should select when it opens (set from the menu panel's context menu).
    var settingsFocusZone: Int?
    var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    let privacyGuard: PrivacyGuard

    /// False in tests: no windows, overlays, sounds or on-screen feedback.
    @ObservationIgnored let presentsUI: Bool
    /// Runs a zone's action; tests replace it to record instead of acting.
    @ObservationIgnored var performAction: ((ZoneAction) -> String?)!
    @ObservationIgnored let detector = TapDetector()
    @ObservationIgnored let input = InputMonitor()
    @ObservationIgnored let imu = IMUReader()
    @ObservationIgnored let store: Store
    @ObservationIgnored private var model: ZoneModel?
    @ObservationIgnored private var features: [Int: [Double]] = [:]  // sample id -> features
    @ObservationIgnored private var nextSampleID = 1
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var statusTimer: Timer?
    @ObservationIgnored private var trainGeneration = 0
    @ObservationIgnored private var heartbeat = 0
    @ObservationIgnored private var testHookObserver: NSObjectProtocol?

    var grid: Grid { dataset.grid }
    var isTrained: Bool { model != nil }
    var lastRecord: TapRecord? { recent.first }
    var dataDirectory: URL { store.directory }

    var accuracy: Double? {
        guard let report, let kind = activeKind else { return nil }
        return report.accuracy(kind)
    }

    init(store: Store, presentsUI: Bool) {
        self.store = store
        self.presentsUI = presentsUI
        privacyGuard = PrivacyGuard(presentsOverlay: presentsUI, micRecoveryURL: store.micRecoveryURL)
        config = store.loadConfig()
        dataset = store.loadDataset()
        nextSampleID = (dataset.samples.map(\.id).max() ?? 0) + 1
        for s in dataset.samples { features[s.id] = Features.extract(g: s.g, a: s.a) }
        if config.actions.isEmpty { config.actions = ZoneAction.defaults(for: dataset.grid) }
        if config.detector.refractory < 0.5 { config.detector.refractory = 0.5 }  // older default was 0.35 s
        detector.settings = config.detector
        privacyGuard.muteMic = config.guardMutesMic
        privacyGuard.stopCamera = config.guardStopsCamera
        performAction = { [unowned self] action in ActionRunner.perform(action, guardController: privacyGuard) }
    }

    func start() {
        Log.app.notice("LidTap starting, data in \(self.store.directory.path, privacy: .public)")
        privacyGuard.recoverMicAfterCrash()
        detector.lidAngle = { [imu] in imu.lidAngle }
        detector.onTap = { [weak self] event in
            DispatchQueue.main.async { self?.handle(event) }
        }
        imu.onSample = { [detector] kind, t, v in detector.process(kind, time: t, value: v) }
        imu.start()
        input.start()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStatus() }
        }
        if Set(dataset.samples.map(\.label)).count >= 2 { retrain() }
        // Any process can post distributed notifications, so the hooks only ever run against a separate test data
        // directory, never your real calibration and settings.
        if CommandLine.arguments.contains("--test-hooks") {
            if ProcessInfo.processInfo.environment["LIDTAP_DATA_DIR"] != nil { installTestHooks() }
            else { Log.app.error("--test-hooks ignored: it needs LIDTAP_DATA_DIR (a test data directory)") }
        }
    }

    private func refreshStatus() {
        let d = detector.currentStatus()
        var s = SensorStatus(rate: d.gyroRate, lid: imu.lidAngle, noise: d.noise, threshold: d.threshold,
                             error: imu.error, accessibility: status.accessibility)
        s.accessibility = Permissions.accessibility
        if s.rate > 500 && status.rate <= 500 { Log.sensor.notice("Motion sensor streaming at \(Int(s.rate)) Hz, lid \(s.lid ?? -1)") }
        if s.rate < 50 && status.rate >= 50 { Log.sensor.error("Motion sensor stopped streaming") }
        if let e = s.error, e != status.error { Log.sensor.error("Sensor error: \(e, privacy: .public)") }
        if s.accessibility != status.accessibility { Log.app.notice("Accessibility \(s.accessibility ? "granted" : "not granted", privacy: .public)") }
        if s != status { status = s }
        heartbeat += 1
        if heartbeat % 4 == 0 { writeStatusFile() }
    }

    /// Machine-readable snapshot for diagnostics and tests: <data dir>/status.json, refreshed every second.
    private func writeStatusFile() {
        let modelName: String = activeKind?.rawValue ?? ""
        let acc: Double = accuracy ?? -1
        var info: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier, "time": Date().timeIntervalSince1970,
            "rate": status.rate.rounded(), "lid": status.lid ?? -1, "noise": status.noise, "threshold": status.threshold,
            "accessibility": status.accessibility, "enabled": config.enabled, "trained": isTrained,
            "model": modelName, "accuracy": acc, "grid": grid.title,
            "samples": dataset.samples.count, "guardActive": privacyGuard.isActive,
            "calibrating": calibration != nil, "taps": recent.count,
        ]
        info["recent"] = recent.prefix(10).map { ["id": $0.id, "outcome": "\($0.outcome)", "label": $0.label ?? "", "detail": $0.detail,
                                                  "peak": ($0.peakG * 10).rounded() / 10] as [String: Any] }
        if let r = lastRecord {
            info["last"] = ["id": r.id, "outcome": "\(r.outcome)", "label": r.label ?? "", "detail": r.detail,
                            "confidence": r.confidence ?? -1]
        }
        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]) {
            try? data.write(to: store.statusURL, options: .atomic)
        }
    }

    /// Developer hooks, only with --test-hooks: `dev.lidtap.test` distributed notifications replay a recorded
    /// tap for a zone ("cmd": "tap", "label": "z0"), toggle Privacy Guard ("guard"), or open Settings ("settings").
    private func installTestHooks() {
        Log.app.notice("Test hooks enabled")
        testHookObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("dev.lidtap.test"), object: nil, queue: .main) { [weak self] note in
            let cmd = note.userInfo?["cmd"] as? String ?? ""
            let label = note.userInfo?["label"] as? String ?? ""
            MainActor.assumeIsolated {
                guard let self else { return }
                switch cmd {
                case "tap": if let ev = self.replayEvent(label: label) { self.handle(ev) }
                case "guard": self.privacyGuard.toggle()
                case "settings": self.showSettings()
                case "calibrate": self.startCalibration()
                case "endCalibration": self.endCalibration()
                default: Log.app.error("Unknown test command \(cmd, privacy: .public)")
                }
            }
        }
    }

    private var replayID = 1_000_000

    /// A recorded tap for `label` with a little fresh noise, shaped like a live detector event.
    func replayEvent(label: String, gated: String? = nil) -> TapEvent? {
        guard let s = dataset.samples.filter({ $0.label == label }).randomElement() else { return nil }
        replayID += 1
        let jitter = { (rows: [[Double]], scale: Double) in rows.map { $0.map { $0 + Double.random(in: -scale...scale) } } }
        return TapEvent(id: replayID, time: MachClock.now(), date: Date(), g: jitter(s.g, 0.02), a: jitter(s.a, 0.0002),
                        peakG: s.peakG, peakA: s.peakA, lid: s.lid, threshold: 1, noise: 0.1, gated: gated)
    }

    func showSettings(pane: String? = nil, zone: Int? = nil) {
        if let pane { UserDefaults.standard.set(pane, forKey: "settingsPane") }
        if let zone { settingsFocusZone = zone }
        SettingsWindow.shared.show()
    }

    // MARK: Taps

    func handle(_ event: TapEvent) {
        tapFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.tapFlash = false }
        func record(_ outcome: TapRecord.Outcome, _ label: String?, _ confidence: Double?, _ detail: String, gateDetail: String? = nil) {
            let why = gateDetail ?? event.gateDetail
            Log.sensor.notice("Tap \(event.id): \(String(format: "%.1f", event.peakG), privacy: .public) °/s, \("\(outcome)", privacy: .public) \(label ?? "-", privacy: .public) \(detail, privacy: .public)\(why.map { " [" + $0 + "]" } ?? "", privacy: .public)")
            recent.insert(TapRecord(id: event.id, date: event.date, outcome: outcome, label: label, confidence: confidence,
                                    detail: detail, peakG: event.peakG, peakA: event.peakA, lid: event.lid, gyro: event.g), at: 0)
            if recent.count > 50 { recent.removeLast(recent.count - 50) }
        }

        var noiseRecording = false
        if case .noise = calibration?.phase { noiseRecording = true }
        // During the bump step everything is recorded, typing and clicking included: that is how the
        // recogniser learns what they feel like and learns to reject them.
        if !noiseRecording, let (reason, detail) = inputGate(event) {
            record(.ignored, nil, nil, "Ignored: \(reason)", gateDetail: detail)
            if calibration?.phase == .taps { flash(.ignored(reason)) }
            return
        }

        if var cal = calibration {
            switch cal.phase {
            case .taps:
                guard let label = cal.target else { return }
                cal.lastStrength = event.peakG
                cal.strengthID += 1
                // Record only crisp taps: a soft tap barely above the sensor's background motion teaches the wrong thing.
                if event.peakG < config.minTapStrength {
                    calibration = cal
                    record(.ignored, nil, nil, String(format: "Too soft (%.1f °/s)", event.peakG))
                    flash(.ignored("too soft"))
                    return
                }
                addSample(event, label: label)
                cal.position += 1
                if cal.position >= cal.sequence.count { cal.phase = .noisePrompt }
                calibration = cal
                flash(.recorded(label))
                if let z = zoneIndex(label) { ripple = (z, (ripple?.id ?? 0) + 1) }
                if config.playSounds && presentsUI { NSSound(named: "Tink")?.play() }
                record(.recorded, label, nil, "Recorded for Zone \((zoneIndex(label) ?? 0) + 1)")
            case .noise:
                addSample(event, label: noiseLabel)
                record(.recorded, noiseLabel, nil, "Recorded as a not-a-tap example")
            default:
                break
            }
            return
        }

        guard config.enabled else { return }
        if event.peakG < config.minTapStrength {
            record(.rejected, nil, nil, String(format: "Too soft (%.1f °/s). Tap a little crisper", event.peakG))
            return
        }
        guard let model else {
            record(.untrained, nil, nil, "Tap detected. Calibrate to map it to a zone")
            return
        }
        let p = model.predict(Features.extract(g: event.g, a: event.a), rejectFactor: config.rejectFactor)
        let action = config.actions[p.label] ?? ZoneAction()

        if privacyGuard.isActive {
            if p.rejected == nil && action.kind == .privacyGuard {
                privacyGuard.release()
                record(.acted, p.label, p.confidence, "Privacy Guard off")
            } else {
                record(.guarded, p.label, p.confidence, "Ignored while Privacy Guard is on")
            }
            return
        }
        // Privacy Guard hides the screen and mutes the mic, so a guess must be much surer before it fires.
        let floor = action.kind == .privacyGuard ? max(config.minConfidence, 0.85) : config.minConfidence
        let confidence = p.confidence
        if let reason = p.rejected ?? (confidence < floor ? "Not sure which zone" : nil) {
            record(.rejected, p.label, confidence, reason)
            if presentsUI && config.showTapFeedback { TapFeedback.shared.show(zone: nil, grid: grid, action: nil) }
            return
        }
        let error = performAction(action)
        record(.acted, p.label, confidence, error ?? action.title)
        if let z = zoneIndex(p.label) { ripple = (z, (ripple?.id ?? 0) + 1) }
        Log.action.notice("Zone \(p.label, privacy: .public) (\(Int(confidence * 100))%) -> \(action.title, privacy: .public)\(error.map { " failed: " + $0 } ?? "", privacy: .public)")
        if presentsUI && config.showTapFeedback && action.kind != .privacyGuard {
            TapFeedback.shared.show(zone: zoneIndex(p.label), grid: grid, action: action)
        }
        if presentsUI && config.playSounds && action.kind != .none && error == nil { NSSound(named: "Pop")?.play() }
    }

    /// Should input around this tap disqualify it? Typing and clicking shake the laptop like a tap, and macOS
    /// may report the key or click shortly *after* the vibration starts, so look on both sides of the tap.
    /// - While calibrating zones, only clicks count (pressing Undo or Stop); keys are ignored, because some Macs
    ///   report a key event right after a lid tap and that must not block calibration.
    /// - Otherwise: any key, click or scroll from `gateSeconds` before to 0.15 s after the tap, or a typing
    ///   burst (3+ key events in the 1.5 s before) means the tap is ignored.
    /// - Lid movement is reported by the detector.
    func inputGate(_ event: TapEvent) -> (reason: String, detail: String)? {
        let t0 = event.time
        if let lid = event.gated, config.detector.gating { return (lid, event.gateDetail ?? lid) }
        guard config.detector.gating else { return nil }
        // A deliberate tap starts from a still screen: wait-for-the-wobble, as people naturally do.
        // The limit scales with the resting noise, whose own peaks over 300 ms reach about 4x its RMS.
        if event.preMotion > max(0.6 * event.threshold, 5 * event.noise, 0.6) {
            return ("still moving", String(format: "%.1f °/s of motion in the 300 ms before (trigger %.1f)", event.preMotion, event.threshold))
        }
        let before = config.detector.gateSeconds, after = 0.15
        func describe(_ what: String, _ times: [Double]) -> String {
            let nearest = times.min { abs($0 - t0) < abs($1 - t0) } ?? t0
            let ms = Int(((nearest - t0) * 1000).rounded())
            return "\(what) \(abs(ms)) ms \(ms < 0 ? "before" : "after") the tap"
        }
        let clicks = input.times([.click], from: t0 - before, to: t0 + (calibration?.phase == .taps ? 0.1 : after))
        if !clicks.isEmpty { return ("click", describe("click", clicks)) }
        // A hand on the trackpad or mouse shakes the laptop, and nobody taps the lid while steering the pointer.
        let moves = input.times([.move], from: t0 - before, to: t0 + after)
        if !moves.isEmpty { return ("pointer moving", describe("pointer move", moves)) }
        if calibration?.phase == .taps { return nil }
        let keys = input.times([.key], from: t0 - before, to: t0 + after)
        if !keys.isEmpty { return ("typing", describe("key", keys)) }
        let burst = input.times([.key], from: t0 - 1.5, to: t0)
        if burst.count >= 3 { return ("typing", "\(burst.count) keys in the last 1.5 s") }
        let scrolls = input.times([.scroll], from: t0 - before, to: t0 + after)
        if !scrolls.isEmpty { return ("scroll", describe("scroll", scrolls)) }
        return nil
    }

    private func flash(_ f: CalibrationState.Flash) {
        guard var cal = calibration else { return }
        cal.flash = f
        cal.flashID += 1
        calibration = cal
    }

    private func addSample(_ event: TapEvent, label: String) {
        let s = TapSample(id: nextSampleID, label: label, wall: event.date.timeIntervalSince1970, lid: event.lid,
                          peakG: event.peakG, peakA: event.peakA,
                          g: event.g.map { $0.map { ($0 * 1000).rounded() / 1000 } },
                          a: event.a.map { $0.map { ($0 * 10000).rounded() / 10000 } })
        nextSampleID += 1
        features[s.id] = Features.extract(g: s.g, a: s.a)
        dataset.samples.append(s)
        scheduleSave()
    }

    /// Writes a pending dataset save now (on quit, so the last taps of a calibration aren't lost).
    func flushSave() {
        guard saveTask != nil else { return }
        saveTask?.cancel()
        saveTask = nil
        store.save(dataset)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = dataset, store = store
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            store.save(snapshot)
        }
    }

    // MARK: Calibration

    func startCalibration(grid newGrid: Grid? = nil, perZone: Int = 15, block: Int = 5) {
        let target = newGrid ?? dataset.grid
        if target != dataset.grid {
            dataset.samples.removeAll { $0.label != noiseLabel }
            dataset.grid = target
            report = nil
            model = nil
            activeKind = nil
            config.actions = ZoneAction.defaults(for: target)
            scheduleSave()
        }
        var need: [String: Int] = [:]
        for i in 0..<target.count { need[zoneLabel(i)] = max(0, perZone - usableCount(for: zoneLabel(i))) }
        if need.values.allSatisfy({ $0 == 0 }) {
            // Every zone is full: top each one up by another round.
            for i in 0..<target.count { need[zoneLabel(i)] = min(block, perZone) }
        }
        var sequence: [String] = []
        var rng = SystemRandomNumberGenerator()
        while need.values.contains(where: { $0 > 0 }) {
            for z in need.filter({ $0.value > 0 }).keys.shuffled(using: &rng) {
                let take = min(block, need[z]!)
                sequence += Array(repeating: z, count: take)
                need[z]! -= take
            }
        }
        calibration = CalibrationState(grid: target, perZone: perZone, sequence: sequence)
        if presentsUI { CalibrationWindow.shared.show() }
    }

    func undoLastCalibrationTap() {
        guard var cal = calibration, cal.phase == .taps, cal.position > 0,
              let last = dataset.samples.lastIndex(where: { $0.label == cal.sequence[cal.position - 1] }) else { return }
        dataset.samples.remove(at: last)
        cal.position -= 1
        calibration = cal
        scheduleSave()
    }

    func startNoiseRecording(seconds: Double = 20) {
        guard var cal = calibration else { return }
        let until = Date().addingTimeInterval(seconds)
        cal.phase = .noise(until: until)
        calibration = cal
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            // Only end the recording this timer started, not a newer one begun after a restart.
            if case .noise(let u) = calibration?.phase, u == until { finishCalibration() }
        }
    }

    func finishCalibration() {
        guard var cal = calibration else { return }
        cal.phase = .training
        calibration = cal
        retrain { [weak self] in
            guard let self, var c = self.calibration else { return }
            c.phase = .done
            self.calibration = c
        }
    }

    func endCalibration() {
        let wasCollecting = calibration?.phase == .taps && (calibration?.position ?? 0) > 0
        calibration = nil
        if presentsUI { CalibrationWindow.shared.hide() }
        if wasCollecting { retrain() }
    }

    // MARK: Data

    func deleteSamples(label: String) {
        dataset.samples.removeAll { $0.label == label }
        scheduleSave()
        retrain()
    }

    func clearData() {
        dataset.samples.removeAll()
        discardTraining()
        report = nil
        model = nil
        activeKind = nil
        scheduleSave()
    }

    func count(for label: String) -> Int { dataset.count(label) }

    /// Recorded taps strong enough to learn from (bumps always count: they teach what isn't a tap).
    func isUsable(_ s: TapSample) -> Bool { s.label == noiseLabel || s.peakG >= config.minTapStrength }
    func usableCount(for label: String) -> Int { dataset.samples.reduce(0) { $0 + ($1.label == label && isUsable($1) ? 1 : 0) } }
    var softTapCount: Int { dataset.samples.filter { !isUsable($0) }.count }

    @ObservationIgnored private var retrainTask: Task<Void, Never>?
    private func scheduleRetrain() {
        retrainTask?.cancel()
        retrainTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            if !Task.isCancelled { retrain() }
        }
    }

    // MARK: Training

    func retrain(completion: (() -> Void)? = nil) {
        let samples = dataset.samples.filter(isUsable)
        let X = samples.map { features[$0.id] ?? Features.extract(g: $0.g, a: $0.a) }
        let labels = samples.map(\.label)
        let grid = dataset.grid
        guard Set(labels).count >= 2 else {
            discardTraining()
            report = nil
            model = nil
            activeKind = nil
            completion?()
            return
        }
        trainGeneration += 1
        let generation = trainGeneration
        isTraining = true
        let choice = config.modelChoice
        Task.detached(priority: .userInitiated) {
            let augmented = samples.map { Augment.variants(of: $0) }
            let report = Evaluator.evaluate(X: X, labels: labels, grid: grid, augmented: augmented)
            let kind = ModelKind(rawValue: choice) ?? report.best
            let model = ZoneModel(kind: kind, X: X, labels: labels, augmented: augmented)
            await MainActor.run {
                guard generation == self.trainGeneration else { return }
                self.report = report
                self.model = model
                self.activeKind = kind
                self.isTraining = false
                Log.app.notice("Trained \(kind.title, privacy: .public) on \(report.sampleCount) taps (\(grid.title, privacy: .public)), accuracy \(Int((report.accuracy(kind) ?? 0) * 100))%")
                completion?()
            }
        }
    }

    /// Makes any training still running in the background drop its result (it learned from data that is gone).
    private func discardTraining() {
        trainGeneration += 1
        isTraining = false
    }

    private func refitActiveModel() {
        guard let report else { return }
        let kind = ModelKind(rawValue: config.modelChoice) ?? report.best
        guard kind != activeKind || model == nil else { return }
        let samples = dataset.samples.filter(isUsable)
        let X = samples.map { features[$0.id] ?? Features.extract(g: $0.g, a: $0.a) }
        let labels = samples.map(\.label)
        guard Set(labels).count >= 2 else { return }
        let generation = trainGeneration
        Task.detached(priority: .userInitiated) {
            let model = ZoneModel(kind: kind, X: X, labels: labels, augmented: samples.map { Augment.variants(of: $0) })
            await MainActor.run {
                // A retrain or a data change since then wins over this refit.
                guard generation == self.trainGeneration else { return }
                self.model = model
                self.activeKind = kind
            }
        }
    }

    // MARK: Settings helpers

    func action(for zone: Int) -> ZoneAction { config.actions[zoneLabel(zone)] ?? ZoneAction() }

    func setAction(_ action: ZoneAction, for zone: Int) { config.actions[zoneLabel(zone)] = action }

    func testAction(zone: Int) {
        let action = action(for: zone)
        ripple = (zone, (ripple?.id ?? 0) + 1)
        _ = performAction(action)
        if presentsUI && config.showTapFeedback && action.kind != .privacyGuard { TapFeedback.shared.show(zone: zone, grid: grid, action: action) }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.app.error("Launch at login failed: \(error.localizedDescription, privacy: .public)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
