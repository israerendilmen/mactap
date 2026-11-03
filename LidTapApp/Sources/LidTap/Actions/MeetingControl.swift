import AppKit
import CoreAudio
import CoreMediaIO

// MARK: - Microphones

/// Mutes every audio input device at the system level and restores each one exactly afterwards.
/// Works whatever meeting app is listening, because the app simply receives silence.
final class MicMuter {
    private struct Saved {
        let device: AudioDeviceID
        let mute: UInt32?
        let volumes: [(AudioObjectPropertyElement, Float32)]
    }

    /// What `recoveryURL` holds: each device's settings before muting, keyed by its UID (device IDs change between launches).
    private struct Record: Codable {
        let uid: String
        let mute: UInt32?
        let volumes: [Volume]
        struct Volume: Codable { let element: UInt32; let value: Float32 }
    }

    private var saved: [Saved] = []
    private(set) var mutedCount = 0
    var isEngaged: Bool { !saved.isEmpty }
    /// While muted, the original settings are also kept here, so a crash or force quit can't leave the mic silenced for good.
    let recoveryURL: URL?

    init(recoveryURL: URL? = nil) { self.recoveryURL = recoveryURL }

    private static func uid(_ id: AudioDeviceID) -> String? {
        var addr = address(kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    private static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func inputDevices() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { id in
            var a = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
            var s: UInt32 = 0
            return AudioObjectGetPropertyDataSize(id, &a, 0, nil, &s) == noErr && s > 0
        }
    }

    private static func settable(_ id: AudioDeviceID, _ addr: inout AudioObjectPropertyAddress) -> Bool {
        guard AudioObjectHasProperty(id, &addr) else { return false }
        var ok: DarwinBoolean = false
        return AudioObjectIsPropertySettable(id, &addr, &ok) == noErr && ok.boolValue
    }

    /// Mutes all inputs. Returns how many devices were silenced.
    @discardableResult
    func mute() -> Int {
        reassert()
        return mutedCount
    }

    /// Re-applies the mute (meeting apps with automatic gain may raise the volume again), including on any
    /// microphone plugged in since the guard went on (AirPods, a USB headset), which is restored afterwards too.
    func reassert() {
        if saveNewDevices() { writeRecovery() }
        for s in saved {
            if s.mute != nil {
                var a = Self.address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeInput)
                var one: UInt32 = 1
                AudioObjectSetPropertyData(s.device, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &one)
            }
            for (element, _) in s.volumes {
                var a = Self.address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeInput, element)
                var zero: Float32 = 0
                AudioObjectSetPropertyData(s.device, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &zero)
            }
        }
        mutedCount = saved.count
    }

    /// Records the current mute and volume of every input device not saved yet. Returns whether any was added.
    private func saveNewDevices() -> Bool {
        let before = saved.count
        let known = Set(saved.map(\.device))
        for id in Self.inputDevices() where !known.contains(id) {
            var muteAddr = Self.address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeInput)
            var mute: UInt32?
            if Self.settable(id, &muteAddr) {
                var v: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
                if AudioObjectGetPropertyData(id, &muteAddr, 0, nil, &size, &v) == noErr { mute = v }
            }
            var volumes: [(AudioObjectPropertyElement, Float32)] = []
            for element in [kAudioObjectPropertyElementMain] + (1...8).map({ AudioObjectPropertyElement($0) }) {
                var volAddr = Self.address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeInput, element)
                guard Self.settable(id, &volAddr) else { continue }
                var v: Float32 = 0, size = UInt32(MemoryLayout<Float32>.size)
                if AudioObjectGetPropertyData(id, &volAddr, 0, nil, &size, &v) == noErr { volumes.append((element, v)) }
            }
            if mute != nil || !volumes.isEmpty { saved.append(Saved(device: id, mute: mute, volumes: volumes)) }
        }
        return saved.count > before
    }

    private func writeRecovery() {
        guard let recoveryURL else { return }
        let records = saved.compactMap { s in
            Self.uid(s.device).map { Record(uid: $0, mute: s.mute, volumes: s.volumes.map { Record.Volume(element: $0.0, value: $0.1) }) }
        }
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: recoveryURL, options: .atomic)
    }

    /// Puts back the microphones a previous run muted but never restored (it crashed or was force quit).
    /// Returns how many devices were restored.
    @discardableResult
    func recoverAfterCrash() -> Int {
        guard let recoveryURL, let data = try? Data(contentsOf: recoveryURL) else { return 0 }
        defer { try? FileManager.default.removeItem(at: recoveryURL) }
        guard let records = try? JSONDecoder().decode([Record].self, from: data) else { return 0 }
        let byUID = Dictionary(records.map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
        var restored = 0
        for id in Self.inputDevices() {
            guard let uid = Self.uid(id), let r = byUID[uid] else { continue }
            Self.apply(Saved(device: id, mute: r.mute, volumes: r.volumes.map { ($0.element, $0.value) }))
            restored += 1
        }
        return restored
    }

    private static func apply(_ s: Saved) {
        for (element, value) in s.volumes {
            var a = address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeInput, element)
            var v = value
            AudioObjectSetPropertyData(s.device, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        }
        if var m = s.mute {
            var a = address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeInput)
            AudioObjectSetPropertyData(s.device, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
        }
    }

    func restore() {
        for s in saved { Self.apply(s) }
        saved = []
        mutedCount = 0
        if let recoveryURL { try? FileManager.default.removeItem(at: recoveryURL) }
    }
}

// MARK: - Cameras

enum Cameras {
    /// True if any camera is currently streaming to any app.
    static func anyRunning() -> Bool {
        var addr = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                             mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                             mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, size, &used, &ids) == noErr else { return false }
        for id in ids {
            var runAddr = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                                                    mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                    mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            var running: UInt32 = 0
            var got: UInt32 = 0
            if CMIOObjectGetPropertyData(id, &runAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &got, &running) == noErr, running != 0 {
                return true
            }
        }
        return false
    }
}

// MARK: - Meeting apps

/// A meeting the camera shortcut can be sent to.
struct MeetingTarget: Equatable {
    let name: String
    let bundleID: String
    let key: KeySender.Key
    let flags: CGEventFlags
    let isBrowserMeet: Bool

    static func == (a: MeetingTarget, b: MeetingTarget) -> Bool { a.bundleID == b.bundleID && a.isBrowserMeet == b.isBrowserMeet }
}

enum Meetings {
    private static let natives: [(String, [String], KeySender.Key, CGEventFlags)] = [
        ("Zoom", ["us.zoom.xos"], .v, [.maskCommand, .maskShift]),
        ("Microsoft Teams", ["com.microsoft.teams2", "com.microsoft.teams"], .o, [.maskCommand, .maskShift]),
        ("Webex", ["Cisco-Systems.Spark"], .v, [.maskCommand, .maskShift]),
    ]
    private static let browsers: [(String, String)] = [
        ("Google Chrome", "com.google.Chrome"), ("Microsoft Edge", "com.microsoft.edgemac"),
        ("Brave", "com.brave.Browser"), ("Safari", "com.apple.Safari"),
    ]

    /// Finds the meeting to act on: the frontmost meeting app first, then any running one,
    /// then a browser with a Google Meet tab (which this also brings to the front).
    static func locate() async -> MeetingTarget? {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        if let native = nativeTarget(front: front, running: running) { return native }
        for (name, id) in browserOrder(front: front, running: running) {
            if await focusMeetTab(browserID: id) {
                return MeetingTarget(name: "Google Meet (\(name))", bundleID: id, key: .e, flags: .maskCommand, isBrowserMeet: true)
            }
        }
        return nil
    }

    /// The native meeting app to use: the frontmost one, else the first running one.
    static func nativeTarget(front: String?, running: Set<String>) -> MeetingTarget? {
        var candidates: [MeetingTarget] = []
        for (name, ids, key, flags) in natives {
            for id in ids where running.contains(id) {
                candidates.append(MeetingTarget(name: name, bundleID: id, key: key, flags: flags, isBrowserMeet: false))
            }
        }
        return candidates.first { $0.bundleID == front } ?? candidates.first
    }

    /// Running browsers to search for a Meet tab, frontmost first.
    static func browserOrder(front: String?, running: Set<String>) -> [(String, String)] {
        let present = browsers.filter { running.contains($0.1) }
        return present.filter { $0.1 == front } + present.filter { $0.1 != front }
    }

    /// Selects a meet.google.com tab and raises its window. Uses AppleScript (asks for Automation once).
    static func focusMeetTab(browserID: String) async -> Bool {
        let script: String
        if browserID == "com.apple.Safari" {
            script = """
            tell application id "com.apple.Safari"
              repeat with w in windows
                repeat with t in tabs of w
                  if URL of t contains "meet.google.com/" then
                    set current tab of w to t
                    set index of w to 1
                    return "ok"
                  end if
                end repeat
              end repeat
            end tell
            return "none"
            """
        } else {
            script = """
            tell application id "\(browserID)"
              repeat with w in windows
                set i to 0
                repeat with t in tabs of w
                  set i to i + 1
                  if URL of t contains "meet.google.com/" then
                    set active tab index of w to i
                    set index of w to 1
                    return "ok"
                  end if
                end repeat
              end repeat
            end tell
            return "none"
            """
        }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                p.arguments = ["-e", script]
                let out = Pipe()
                p.standardOutput = out
                p.standardError = Pipe()
                do {
                    try p.run()
                    p.waitUntilExit()
                    let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    cont.resume(returning: text.trimmingCharacters(in: .whitespacesAndNewlines) == "ok")
                } catch {
                    cont.resume(returning: false)
                }
            }
        }
    }

    /// Brings the meeting forward and sends its camera toggle shortcut.
    @MainActor
    static func toggleCamera(_ target: MeetingTarget) async {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: target.bundleID).first {
            app.unhide()
            app.activate()
        }
        for _ in 0..<20 where NSWorkspace.shared.frontmostApplication?.bundleIdentifier != target.bundleID {
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .milliseconds(150))
        KeySender.press(target.key, flags: target.flags)
    }
}
