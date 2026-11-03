import Foundation

/// AppModel end to end with a temporary data folder, no UI, and actions recorded instead of performed.
@MainActor
final class AppHarness {
    let dir: URL
    let app: AppModel
    var performed: [ZoneAction] = []

    init(name: String, dataset: Dataset? = T.loadDataset(), config: AppConfig? = nil) {
        dir = T.tempDir(name)
        let store = Store(directory: dir)
        if let dataset { store.save(dataset) }
        if let config { store.save(config) }
        app = AppModel(store: store, presentsUI: false)
        app.input.allowsSystemFallback = false  // input history comes only from what a test records
        app.privacyGuard.muteMic = false
        app.privacyGuard.stopCamera = false
        app.performAction = { [unowned self] action in
            self.performed.append(action)
            if action.kind == .privacyGuard { self.app.privacyGuard.toggle() }
            return nil
        }
    }

    func train() -> Bool {
        app.retrain()
        return T.wait(30) { app.isTrained && !app.isTraining }
    }

    func tap(_ label: String, gated: String? = nil) {
        app.handle(app.replayEvent(label: label, gated: gated)!)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }
}

@MainActor
func appLogicTests() {
    T.suite = "App logic"
    print("\n▶ App logic")

    T.run("loads your data and trains the best model") {
        let h = AppHarness(name: "train")
        T.expect(h.app.dataset.samples.count == 60, "samples \(h.app.dataset.samples.count)")
        T.expect(h.train(), "model did not train within 30 s")
        T.note("active model \(h.app.activeKind?.title ?? "-"), accuracy \(Int((h.app.accuracy ?? 0) * 100))%")
        T.expect((h.app.accuracy ?? 0) >= 0.85, "accuracy \(h.app.accuracy ?? 0)")
        T.expect(h.app.config.actions.count == 4, "default actions for 2×2: \(h.app.config.actions.count)")
    }

    T.run("each zone's tap runs that zone's action") {
        let h = AppHarness(name: "dispatch")
        guard h.train() else { return T.fail("no model") }
        var right = 0, total = 0
        for zone in 0..<4 {
            for _ in 0..<15 {
                h.performed.removeAll()
                h.tap(zoneLabel(zone))
                total += 1
                let r = h.app.lastRecord!
                if r.outcome == .acted && r.label == zoneLabel(zone) && h.performed == [h.app.action(for: zone)] { right += 1 }
                if h.app.privacyGuard.isActive { h.app.privacyGuard.release() }
            }
        }
        T.note("correct zone + action: \(right)/\(total)")
        T.expect(Double(right) / Double(total) >= 0.85, "only \(right)/\(total) taps ran the right action")
    }

    T.run("gated taps never act") {
        let h = AppHarness(name: "gated")
        guard h.train() else { return T.fail("no model") }
        for reason in ["typing", "click", "scroll", "lid moved"] { h.tap("z0", gated: reason) }
        T.expect(h.performed.isEmpty, "gated taps performed \(h.performed.count) actions")
        T.expect(h.app.recent.prefix(4).allSatisfy { $0.outcome == .ignored }, "gated taps not recorded as ignored")
    }

    T.run("typing filter: keys before or after a tap, and typing bursts") {
        let h = AppHarness(name: "inputgate")
        guard h.train() else { return T.fail("no model") }
        var clock = MachClock.now()
        @MainActor func tap(_ label: String, keys: [Double] = [], clicks: [Double] = [], moves: [Double] = []) -> TapRecord.Outcome? {
            clock += 10  // each simulated tap 10 s after the last, so input from one never touches the next
            let r = h.app.replayEvent(label: label)!
            let ev = TapEvent(id: r.id, time: clock, date: r.date, g: r.g, a: r.a, peakG: r.peakG, peakA: r.peakA,
                              lid: r.lid, threshold: r.threshold, noise: r.noise, gated: nil)
            for k in keys { h.app.input.record(.key, at: ev.time + k) }
            for c in clicks { h.app.input.record(.click, at: ev.time + c) }
            for m in moves { h.app.input.record(.move, at: ev.time + m) }
            h.app.handle(ev)
            return h.app.lastRecord?.outcome
        }
        T.expect(tap("z0", keys: [-0.05]) == .ignored, "key 50 ms before the tap should ignore it")
        T.expect(tap("z0", keys: [0.08]) == .ignored, "key 80 ms after the tap (typing reported late) should ignore it")
        T.expect(tap("z0", keys: [-1.2, -0.9, -0.6]) == .ignored, "typing burst should ignore the tap")
        T.expect(tap("z0", clicks: [0.12]) == .ignored, "trackpad click/release just after should ignore it")
        T.expect(tap("z0", moves: [-0.25, -0.15, -0.05]) == .ignored, "a tap while the pointer is moving should be ignored")
        T.expect(tap("z0", moves: [0.1]) == .ignored, "a pointer move just after the tap should ignore it")
        T.expect(tap("z1", moves: [-0.8]) != .ignored, "a pointer move 0.8 s earlier should not block a tap")
        T.sleep(0.01)
        T.expect(tap("z1", keys: [-0.6]) != .ignored, "a single key 0.6 s earlier should not block a tap")
        T.expect(tap("z1", keys: [0.3]) != .ignored, "a key 0.3 s after should not block a tap")
        T.note("ignore reason example: \(h.app.recent.dropFirst(2).first?.detail ?? "-")")
    }

    T.run("calibration: keys never block taps, clicks on Undo/Stop do; bump step records everything") {
        let h = AppHarness(name: "calgate")
        h.app.startCalibration(perZone: 18, block: 1)
        let before = h.app.dataset.samples.count
        var ev = h.app.replayEvent(label: h.app.calibration!.target!)!
        h.app.input.record(.key, at: ev.time + 0.014)   // the key-after-tap pattern seen on this Mac
        h.app.handle(ev)
        T.expect(h.app.dataset.samples.count == before + 1, "a key right after a calibration tap blocked it")
        ev = h.app.replayEvent(label: h.app.calibration!.target!)!
        h.app.input.record(.click, at: ev.time - 0.05)  // clicking Undo shakes the laptop too
        h.app.handle(ev)
        T.expect(h.app.dataset.samples.count == before + 1, "a click on the calibration controls was recorded as a tap")
        ev = h.app.replayEvent(label: h.app.calibration!.target!)!
        h.app.input.record(.move, at: ev.time - 0.1)
        h.app.handle(ev)
        T.expect(h.app.dataset.samples.count == before + 1, "a tap while moving the pointer was recorded in calibration")
        h.app.startNoiseRecording(seconds: 30)
        ev = h.app.replayEvent(label: "z0")!
        h.app.input.record(.key, at: ev.time + 0.02)
        h.app.handle(ev)
        T.expect(h.app.count(for: noiseLabel) == 1, "typing during the bump step was not recorded as a bump")
        h.app.endCalibration()
    }

    T.run("stillness: a tap that starts while the screen is still moving is ignored") {
        let h = AppHarness(name: "still")
        guard h.train() else { return T.fail("no model") }
        @MainActor func tap(pre: Double) -> TapRecord.Outcome? {
            let r = h.app.replayEvent(label: "z0")!
            h.app.handle(TapEvent(id: r.id, time: r.time, date: r.date, g: r.g, a: r.a, peakG: r.peakG, peakA: r.peakA, lid: r.lid,
                                  threshold: 1.2, noise: 0.15, gated: nil, preMotion: pre))
            return h.app.lastRecord?.outcome
        }
        T.expect(tap(pre: 0.3) != .ignored, "a tap from a still screen was ignored")
        T.expect(tap(pre: 1.0) == .ignored, "a tap during motion (typing, wobble) was not ignored")
        T.note(h.app.lastRecord?.detail ?? "")
    }

    T.run("calibration records only clean taps (too-soft taps are asked again)") {
        let h = AppHarness(name: "soft")
        h.app.startCalibration(perZone: 18, block: 1)
        let n = h.app.dataset.samples.count
        let r = h.app.replayEvent(label: h.app.calibration!.target!)!
        h.app.handle(TapEvent(id: r.id, time: r.time, date: r.date, g: r.g, a: r.a, peakG: 1.2, peakA: r.peakA, lid: r.lid,
                              threshold: 1, noise: 0.1, gated: nil))
        T.expect(h.app.dataset.samples.count == n && h.app.calibration?.flash == .ignored("too soft"), "a 1.2 °/s calibration tap was recorded")
        h.app.handle(TapEvent(id: r.id + 1, time: r.time, date: r.date, g: r.g, a: r.a, peakG: 4, peakA: r.peakA, lid: r.lid,
                              threshold: 1, noise: 0.1, gated: nil))
        T.expect(h.app.dataset.samples.count == n + 1, "a crisp calibration tap was not recorded")
        h.app.endCalibration()
    }

    T.run("Privacy Guard only fires when the recogniser is at least 85% sure") {
        let h = AppHarness(name: "guardconf")
        guard h.train() else { return T.fail("no model") }
        h.app.config.minConfidence = 0.3
        var fired: [Double] = []
        for _ in 0..<40 {
            h.performed.removeAll()
            h.tap("z3")  // the Privacy Guard zone in the default 2×2 layout
            if h.performed.contains(where: { $0.kind == .privacyGuard }) { fired.append(h.app.lastRecord?.confidence ?? 0) }
            if h.app.privacyGuard.isActive { h.app.privacyGuard.release() }
        }
        T.note("fired \(fired.count)/40, lowest confidence \(fired.min().map { String(format: "%.2f", $0) } ?? "-")")
        T.expect(fired.allSatisfy { $0 >= 0.85 }, "Privacy Guard fired below 85% confidence")
    }

    T.run("confidence floor: unsure taps say so instead of acting") {
        let h = AppHarness(name: "confidence")
        guard h.train() else { return T.fail("no model") }
        h.app.config.minConfidence = 0.999
        h.performed.removeAll()
        for _ in 0..<5 { h.tap("z1") }
        let rejected = h.app.recent.prefix(5).filter { $0.outcome == .rejected }.count
        T.expect(rejected >= 4 && h.performed.count <= 1, "with a 99.9% floor, \(rejected)/5 rejected and \(h.performed.count) acted")
        h.app.config.minConfidence = 0.6
        h.performed.removeAll()
        for _ in 0..<5 { h.tap("z1") }
        T.expect(h.performed.count >= 4, "with a 60% floor only \(h.performed.count)/5 acted")
    }

    T.run("strength coaching: soft live taps never act; training uses only crisp taps") {
        var ds = T.loadDataset()
        // Add 12 soft (1.5 °/s) taps, deliberately labelled as zone 1, that would poison training if used.
        for i in 0..<12 {
            var s = ds.samples[30 + i]
            s.id = 1000 + i; s.label = "z0"; s.peakG = 1.5
            ds.samples.append(s)
        }
        let h = AppHarness(name: "strength", dataset: ds)
        T.expect(h.app.softTapCount == 12 && h.app.usableCount(for: "z0") == 15, "soft \(h.app.softTapCount), usable z0 \(h.app.usableCount(for: "z0"))")
        guard h.train() else { return T.fail("no model") }
        T.expect(h.app.report?.sampleCount == 60, "trained on \(h.app.report?.sampleCount ?? 0) taps, want the 60 crisp ones")
        T.expect((h.app.accuracy ?? 0) >= 0.9, "accuracy \(h.app.accuracy ?? 0) with soft taps excluded")
        let r = h.app.replayEvent(label: "z1")!
        h.performed.removeAll()
        h.app.handle(TapEvent(id: r.id, time: r.time, date: r.date, g: r.g, a: r.a, peakG: 2.0, peakA: r.peakA, lid: r.lid,
                              threshold: 1, noise: 0.1, gated: nil))
        T.expect(h.performed.isEmpty && h.app.lastRecord?.outcome == .rejected, "a 2 °/s live tap acted")
        h.app.config.minTapStrength = 1.0
        T.expect(T.wait(10) { h.app.report?.sampleCount == 72 && !h.app.isTraining }, "lowering the minimum did not retrain with all taps")
    }

    T.run("strength coaching: calibration meter sees every tap, recorded or not") {
        let h = AppHarness(name: "meter")
        h.app.startCalibration(perZone: 18, block: 1)
        let r = h.app.replayEvent(label: h.app.calibration!.target!)!
        h.app.handle(TapEvent(id: r.id, time: r.time, date: r.date, g: r.g, a: r.a, peakG: 2.2, peakA: r.peakA, lid: r.lid,
                              threshold: 1, noise: 0.1, gated: nil))
        T.expect(h.app.calibration?.lastStrength == 2.2 && h.app.calibration?.strengthID == 1, "meter missed a soft tap")
        h.app.handle(TapEvent(id: r.id + 1, time: r.time, date: r.date, g: r.g, a: r.a, peakG: 6.5, peakA: r.peakA, lid: r.lid,
                              threshold: 1, noise: 0.1, gated: nil))
        T.expect(h.app.calibration?.lastStrength == 6.5 && h.app.calibration?.position == 1, "meter or progress wrong after a crisp tap")
        h.app.endCalibration()
    }

    T.run("paused app ignores taps") {
        let h = AppHarness(name: "paused")
        guard h.train() else { return T.fail("no model") }
        h.app.config.enabled = false
        h.tap("z0")
        T.expect(h.performed.isEmpty, "acted while paused")
    }

    T.run("unfamiliar taps are rejected without acting") {
        let h = AppHarness(name: "reject")
        guard h.train() else { return T.fail("no model") }
        var rejected = 0
        for i in 0..<20 {
            let g = (0..<TapDetector.n).map { _ in (0..<3).map { _ in Double.random(in: -4...4) } }
            h.app.handle(TapEvent(id: 900 + i, time: MachClock.now(), date: Date(), g: g, a: g.map { $0.map { $0 / 500 } },
                                  peakG: 6, peakA: 0.01, lid: 130, threshold: 1, noise: 0.1, gated: nil))
            if h.app.lastRecord?.outcome == .rejected { rejected += 1 }
        }
        T.note("random windows rejected \(rejected)/20, actions run \(h.performed.count)")
        T.expect(rejected >= 18, "only \(rejected)/20 rejected")
    }

    T.run("untrained app records taps without acting") {
        let h = AppHarness(name: "untrained", dataset: nil)
        h.app.handle(TapEvent(id: 1, time: 0, date: Date(), g: T.loadDataset().samples[0].g, a: T.loadDataset().samples[0].a,
                              peakG: 5, peakA: 0.01, lid: nil, threshold: 1, noise: 0.1, gated: nil))
        T.expect(h.app.lastRecord?.outcome == .untrained && h.performed.isEmpty, "untrained tap outcome \(String(describing: h.app.lastRecord?.outcome))")
    }

    T.run("Privacy Guard: other zones ignored, guard zone releases it") {
        let h = AppHarness(name: "guard")
        guard h.train() else { return T.fail("no model") }
        let guardZone = (0..<4).first { h.app.action(for: $0).kind == .privacyGuard }!
        h.app.privacyGuard.engage()
        T.expect(h.app.privacyGuard.isActive, "guard did not engage")
        h.performed.removeAll()
        let other = zoneLabel((guardZone + 2) % 4)  // a zone in the other row: never confused in your data
        for _ in 0..<5 { h.tap(other) }
        T.expect(h.performed.isEmpty, "zone actions ran while guarded: \(h.performed.map(\.title))")
        T.expect(h.app.recent.prefix(5).allSatisfy { $0.outcome == .guarded || $0.outcome == .rejected }, "taps while guarded not marked guarded")
        for _ in 0..<5 where h.app.privacyGuard.isActive { h.tap(zoneLabel(guardZone)) }
        T.expect(!h.app.privacyGuard.isActive, "tapping the guard zone did not release Privacy Guard")
    }

    T.run("full calibration flow: taps → noise → train → done") {
        let h = AppHarness(name: "calib")
        let before = h.app.dataset.samples.count
        h.app.startCalibration(perZone: 17, block: 1)  // each zone has 15, so 2 more each
        guard let cal = h.app.calibration else { return T.fail("calibration did not start") }
        T.expect(cal.sequence.count == 8, "sequence length \(cal.sequence.count), want 8")
        T.expect(Set(cal.sequence) == Set((0..<4).map(zoneLabel)), "sequence must cover every zone")
        // A gated tap during calibration is flashed and not recorded.
        h.tap("z0", gated: "typing")
        T.expect(h.app.calibration?.position == 0 && h.app.calibration?.flash == .ignored("typing"), "gated calibration tap was counted")
        while let target = h.app.calibration?.target { h.tap(target) }
        T.expect(h.app.calibration?.phase == .noisePrompt, "phase after taps \(String(describing: h.app.calibration?.phase))")
        T.expect(h.app.dataset.samples.count == before + 8, "samples \(h.app.dataset.samples.count), want \(before + 8)")
        h.app.startNoiseRecording(seconds: 0.5)
        for _ in 0..<3 { h.tap("z1") }  // anything during the noise phase is labelled noise
        T.expect(h.app.count(for: noiseLabel) == 3, "noise samples \(h.app.count(for: noiseLabel))")
        T.expect(T.wait(30) { h.app.calibration?.phase == .done }, "never reached done: \(String(describing: h.app.calibration?.phase))")
        T.expect(h.app.isTrained && h.app.report?.labels.contains(noiseLabel) == true, "model not retrained with noise class")
        h.app.endCalibration()
        T.expect(h.app.calibration == nil, "calibration not ended")
    }

    T.run("undo removes the last calibration tap") {
        let h = AppHarness(name: "undo")
        h.app.startCalibration(perZone: 16, block: 1)
        let t = h.app.calibration!.target!
        h.tap(t)
        let n = h.app.dataset.samples.count
        h.app.undoLastCalibrationTap()
        T.expect(h.app.dataset.samples.count == n - 1 && h.app.calibration?.position == 0, "undo did not revert")
        h.app.endCalibration()
    }

    T.run("switching grid clears zone taps, keeps noise, resets actions") {
        let h = AppHarness(name: "grid")
        h.app.startCalibration(perZone: 15)
        h.app.startNoiseRecording(seconds: 30)
        h.tap("z0")
        h.app.endCalibration()
        h.app.startCalibration(grid: Grid(rows: 3, cols: 3), perZone: 5)
        T.expect(h.app.grid == Grid(rows: 3, cols: 3), "grid not switched")
        T.expect(h.app.dataset.zoneTapCount == 0 && h.app.count(for: noiseLabel) == 1, "zone taps \(h.app.dataset.zoneTapCount), noise \(h.app.count(for: noiseLabel))")
        T.expect(h.app.config.actions.count == 9 && h.app.action(for: 8).kind == .privacyGuard, "3×3 default actions")
        T.expect(!h.app.isTrained, "old model kept after grid change")
        T.expect(h.app.calibration?.sequence.count == 45, "3×3 × 5 sequence \(h.app.calibration?.sequence.count ?? 0)")
        h.app.endCalibration()
    }

    T.run("data and settings persist across restarts") {
        let h = AppHarness(name: "persist")
        h.app.setAction(ZoneAction(kind: .openApp, appBundleID: "com.apple.calculator", appName: "Calculator"), for: 2)
        h.app.config.detector.k = 9
        h.app.config.rejectFactor = 2.7
        h.app.startCalibration(perZone: 16, block: 1)
        h.tap(h.app.calibration!.target!)
        h.app.endCalibration()
        T.sleep(0.8)  // dataset saves are debounced
        let again = AppModel(store: Store(directory: h.dir), presentsUI: false)
        T.expect(again.dataset.samples.count == 61, "reloaded samples \(again.dataset.samples.count)")
        T.expect(again.action(for: 2).appBundleID == "com.apple.calculator", "zone action not persisted")
        T.expect(again.config.detector.k == 9 && again.config.rejectFactor == 2.7, "settings not persisted")
        T.expect(again.detector.settings.k == 9, "detector did not pick up saved settings")
    }

    T.run("delete a zone's taps and clear everything") {
        let h = AppHarness(name: "delete")
        h.app.deleteSamples(label: "z0")
        T.expect(h.app.count(for: "z0") == 0 && h.app.dataset.samples.count == 45, "delete zone")
        T.expect(T.wait(20) { !h.app.isTraining }, "retrain after delete hung")
        h.app.clearData()
        T.expect(h.app.dataset.samples.isEmpty && !h.app.isTrained, "clear all")
    }

    T.run("clearing data while a model trains doesn't bring the old model back") {
        let h = AppHarness(name: "clear-race")
        h.app.retrain()
        T.expect(h.app.isTraining, "training did not start")
        h.app.clearData()
        T.expect(!h.app.isTraining, "still marked as training after clear")
        T.sleep(3)  // long enough for the abandoned training to finish
        T.expect(!h.app.isTrained && h.app.report == nil, "model trained on deleted taps came back")
    }

    T.run("quitting writes taps that were still waiting to be saved") {
        let h = AppHarness(name: "flush")
        h.app.startCalibration()
        h.tap(h.app.calibration!.target!)
        h.app.flushSave()  // what applicationWillTerminate does, before the 400 ms debounce
        let again = AppModel(store: Store(directory: h.dir), presentsUI: false)
        T.expect(again.dataset.samples.count == 61, "saved samples \(again.dataset.samples.count)")
    }

    T.run("a stale noise timer doesn't end a newer noise recording") {
        let h = AppHarness(name: "noise-timer")
        h.app.startCalibration()
        h.app.startNoiseRecording(seconds: 0.4)
        h.app.startNoiseRecording(seconds: 30)  // restarted: the first timer must not finish this one
        T.sleep(0.8)
        if case .noise = h.app.calibration?.phase {} else { T.fail("phase \(String(describing: h.app.calibration?.phase))") }
        h.app.endCalibration()
    }

    T.run("corrupt files are moved aside, not overwritten") {
        let dir = T.tempDir("corrupt")
        try! "{ this is not json".write(to: dir.appendingPathComponent("dataset.json"), atomically: true, encoding: .utf8)
        try! "[1,2".write(to: dir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        let app = AppModel(store: Store(directory: dir), presentsUI: false)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        T.note("files after load: \(files.sorted())")
        T.expect(app.dataset.samples.isEmpty && app.config == { var c = AppConfig(); c.actions = ZoneAction.defaults(for: Grid(rows: 2, cols: 2)); return c }(), "defaults not used")
        T.expect(files.filter { $0.contains("corrupt") }.count == 2, "corrupt files not preserved: \(files)")
        try? FileManager.default.removeItem(at: dir)
    }

    T.run("older/partial config files still load (missing keys use defaults)") {
        let dir = T.tempDir("partial")
        try! #"{"enabled": false, "detector": {"k": 4}}"#.write(to: dir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        let cfg = Store(directory: dir).loadConfig()
        T.expect(!cfg.enabled && cfg.detector.k == 4 && cfg.detector.minThreshold == 1 && cfg.rejectFactor == 2 && cfg.guardMutesMic, "partial config \(cfg)")
        try? FileManager.default.removeItem(at: dir)
    }

    T.run("model choice and reject factor apply live") {
        let h = AppHarness(name: "choice")
        guard h.train() else { return T.fail("no model") }
        h.app.config.modelChoice = ModelKind.centroid.rawValue
        T.expect(T.wait(10) { h.app.activeKind == .centroid }, "switching model did not refit (active \(String(describing: h.app.activeKind)))")
        h.app.config.rejectFactor = 0.01  // absurdly strict: everything is unfamiliar
        h.tap("z1")
        T.expect(h.app.lastRecord?.outcome == .rejected, "strict reject factor not applied")
    }

    T.run("tap handling latency (features + predict + dispatch)") {
        let h = AppHarness(name: "latency")
        guard h.train() else { return T.fail("no model") }
        let events = (0..<100).map { _ in h.app.replayEvent(label: zoneLabel(Int.random(in: 0..<4)))! }
        let t0 = Date()
        for e in events { h.app.handle(e); if h.app.privacyGuard.isActive { h.app.privacyGuard.release() } }
        let ms = Date().timeIntervalSince(t0) * 1000 / 100
        T.note(String(format: "%.2f ms per tap on the main thread", ms))
        T.expect(ms < 15, "handling a tap takes \(ms) ms")
    }
}
