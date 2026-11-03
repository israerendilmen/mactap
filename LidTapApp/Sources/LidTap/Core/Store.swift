import Foundation

/// One labelled tap. Same JSON shape as the Python prototype's `data/dataset.json`.
struct TapSample: Codable, Identifiable {
    var id: Int
    var label: String
    var wall: Double
    var lid: Int?
    var peakG: Double
    var peakA: Double
    var g: [[Double]]
    var a: [[Double]]

    enum CodingKeys: String, CodingKey {
        case id, label, wall, lid, g, a
        case peakG = "peak_g", peakA = "peak_a"
    }
}

struct Dataset: Codable {
    var grid = Grid(rows: 2, cols: 2)
    var samples: [TapSample] = []

    func count(_ label: String) -> Int { samples.reduce(0) { $0 + ($1.label == label ? 1 : 0) } }
    var zoneTapCount: Int { samples.filter { $0.label != noiseLabel }.count }
}

struct AppConfig: Codable, Equatable {
    var enabled = true
    var detector = DetectorSettings()
    var rejectFactor = 2.0
    /// Act only when the recogniser is at least this sure; otherwise say "not sure" instead of doing the wrong thing.
    var minConfidence = 0.6
    /// Weakest tap (peak twist, deg/s) LidTap records or acts on. Softer taps sit too close to the sensor's
    /// background motion to tell zones apart (95% accuracy at a 7 °/s median, 56% at 2.3 °/s).
    var minTapStrength = 3.5
    var modelChoice: String = "auto"  // "auto" or a ModelKind raw value
    var actions: [String: ZoneAction] = [:]
    var showTapFeedback = true
    var playSounds = true
    var guardMutesMic = true
    var guardStopsCamera = true

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        detector = try c.decodeIfPresent(DetectorSettings.self, forKey: .detector) ?? d.detector
        rejectFactor = try c.decodeIfPresent(Double.self, forKey: .rejectFactor) ?? d.rejectFactor
        minConfidence = try c.decodeIfPresent(Double.self, forKey: .minConfidence) ?? d.minConfidence
        minTapStrength = try c.decodeIfPresent(Double.self, forKey: .minTapStrength) ?? d.minTapStrength
        modelChoice = try c.decodeIfPresent(String.self, forKey: .modelChoice) ?? d.modelChoice
        actions = try c.decodeIfPresent([String: ZoneAction].self, forKey: .actions) ?? d.actions
        showTapFeedback = try c.decodeIfPresent(Bool.self, forKey: .showTapFeedback) ?? d.showTapFeedback
        playSounds = try c.decodeIfPresent(Bool.self, forKey: .playSounds) ?? d.playSounds
        guardMutesMic = try c.decodeIfPresent(Bool.self, forKey: .guardMutesMic) ?? d.guardMutesMic
        guardStopsCamera = try c.decodeIfPresent(Bool.self, forKey: .guardStopsCamera) ?? d.guardStopsCamera
    }
}

/// Files in ~/Library/Application Support/LidTap (or `LIDTAP_DATA_DIR`, or an explicit directory for tests).
struct Store {
    let directory: URL

    init(directory: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let env = ProcessInfo.processInfo.environment["LIDTAP_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let dir = directory ?? env ?? base.appendingPathComponent("LidTap", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.directory = dir
    }

    var configURL: URL { directory.appendingPathComponent("config.json") }
    var datasetURL: URL { directory.appendingPathComponent("dataset.json") }
    var statusURL: URL { directory.appendingPathComponent("status.json") }
    /// Microphone settings saved while Privacy Guard has them muted (removed once restored).
    var micRecoveryURL: URL { directory.appendingPathComponent("mic-restore.json") }

    /// A file that exists but can't be read is moved aside (never silently replaced by the next save).
    private func quarantine(_ url: URL) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dest = url.deletingPathExtension().appendingPathExtension("corrupt-\(stamp).json")
        try? FileManager.default.moveItem(at: url, to: dest)
        Log.app.error("Unreadable \(url.lastPathComponent, privacy: .public) moved to \(dest.lastPathComponent, privacy: .public)")
    }

    func loadConfig() -> AppConfig {
        guard let data = try? Data(contentsOf: configURL) else { return AppConfig() }
        guard let cfg = try? JSONDecoder().decode(AppConfig.self, from: data) else { quarantine(configURL); return AppConfig() }
        return cfg
    }

    func save(_ config: AppConfig) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(config) { try? data.write(to: configURL, options: .atomic) }
    }

    func loadDataset() -> Dataset {
        guard let data = try? Data(contentsOf: datasetURL) else { return Dataset() }
        guard let ds = try? JSONDecoder().decode(Dataset.self, from: data) else { quarantine(datasetURL); return Dataset() }
        return ds
    }

    func save(_ dataset: Dataset) {
        if let data = try? JSONEncoder().encode(dataset) { try? data.write(to: datasetURL, options: .atomic) }
    }
}
