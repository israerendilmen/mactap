import AppKit
import Observation
import SwiftUI

/// Privacy Guard: blur every screen, mute every microphone and, if a meeting is using the camera,
/// turn the camera off in that meeting app. Tap the Privacy zone again or click to undo all of it.
@MainActor @Observable
final class PrivacyGuard {
    enum MicState: Equatable { case idle, muted(Int), unavailable, skipped }
    enum CameraState: Equatable { case idle, checking, notInUse, turnedOff(String), stillOn(String?), needsAccessibility, skipped }

    private(set) var isActive = false
    private(set) var since: Date?
    private(set) var mic: MicState = .idle
    private(set) var camera: CameraState = .idle

    @ObservationIgnored let presentsOverlay: Bool
    @ObservationIgnored var muteMic = true
    @ObservationIgnored var stopCamera = true
    @ObservationIgnored private let muter: MicMuter
    @ObservationIgnored private var cameraTarget: MeetingTarget?
    @ObservationIgnored private var previousApp: NSRunningApplication?
    @ObservationIgnored private var reassertTimer: Timer?
    @ObservationIgnored private var overlay: PrivacyOverlayController?
    @ObservationIgnored private var cameraTask: Task<Void, Never>?

    /// `micRecoveryURL` keeps the microphones' original settings on disk while muted (see `recoverMicAfterCrash`).
    init(presentsOverlay: Bool = true, micRecoveryURL: URL? = nil) {
        self.presentsOverlay = presentsOverlay
        muter = MicMuter(recoveryURL: micRecoveryURL)
    }

    /// Unmutes microphones left muted by a previous run that crashed or was force quit while the guard was on.
    func recoverMicAfterCrash() {
        let n = muter.recoverAfterCrash()
        if n > 0 { Log.action.notice("Restored \(n) microphone(s) left muted by a previous run") }
    }

    func toggle() { isActive ? release() : engage() }

    func engage() {
        guard !isActive else { return }
        isActive = true
        since = Date()
        previousApp = NSWorkspace.shared.frontmostApplication

        // 1. Hide the screen immediately.
        if presentsOverlay {
            if overlay == nil { overlay = PrivacyOverlayController(guardState: self) }
            overlay?.show()
        }
        Log.action.notice("Privacy Guard on")

        // 2. Silence every microphone.
        if muteMic {
            let n = muter.mute()
            mic = n > 0 ? .muted(n) : .unavailable
            reassertTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.muter.reassert() }
            }
        } else {
            mic = .skipped
        }

        // 3. Turn the camera off in the meeting app that is using it.
        guard stopCamera else { camera = .skipped; return }
        camera = .checking
        cameraTask = Task { @MainActor in
            guard Cameras.anyRunning() else { camera = .notInUse; return }
            guard Permissions.accessibility else { camera = .needsAccessibility; return }
            guard let target = await Meetings.locate() else { camera = .stillOn(nil); return }
            // Released while we were looking for the meeting: don't switch the camera off behind the user's back.
            guard isActive, !Task.isCancelled else { return }
            await Meetings.toggleCamera(target)
            // The shortcut has been sent: remember it now, so a release during the check below toggles it back.
            cameraTarget = target
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(150))
                if !Cameras.anyRunning() { break }
            }
            guard isActive else { return }
            if Cameras.anyRunning() {
                // The shortcut didn't take, so toggling again on release would turn the camera *off*.
                cameraTarget = nil
                camera = .stillOn(target.name)
                Log.action.error("Camera still on after toggling \(target.name, privacy: .public)")
            } else {
                Log.action.notice("Camera turned off in \(target.name, privacy: .public)")
                camera = .turnedOff(target.name)
            }
        }
    }

    func release() {
        guard isActive else { return }
        isActive = false
        cameraTask?.cancel()
        reassertTimer?.invalidate()
        reassertTimer = nil
        overlay?.hide()
        if muter.isEngaged { muter.restore() }
        Log.action.notice("Privacy Guard off")
        let target = cameraTarget, previous = previousApp
        cameraTarget = nil
        mic = .idle
        camera = .idle
        since = nil
        guard let target else { return }
        Task { @MainActor in
            await Meetings.toggleCamera(target)
            if let previous, previous.bundleIdentifier != target.bundleID {
                try? await Task.sleep(for: .milliseconds(300))
                previous.activate()
            }
        }
    }
}

// MARK: - Overlay

/// Never becomes key (so meeting shortcuts still reach the meeting app), and treats any click as "return".
/// The click is caught here, in AppKit: SwiftUI gestures don't fire in a window that can't become key.
private final class OverlayPanel: NSPanel {
    var onClick: (() -> Void)?
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            onClick?()
            return
        }
        super.sendEvent(event)
    }
}

private final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class PrivacyOverlayController {
    private var panels: [NSPanel] = []
    private let guardState: PrivacyGuard

    init(guardState: PrivacyGuard) { self.guardState = guardState }

    func show() {
        hideNow()
        for screen in NSScreen.screens {
            let panel = OverlayPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.isMovable = false
            panel.hidesOnDeactivate = false
            panel.onClick = { [weak guardState] in guardState?.release() }
            panel.appearance = NSAppearance(named: .darkAqua)

            let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: screen.frame.size))
            blur.material = .fullScreenUI
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.appearance = NSAppearance(named: .darkAqua)
            blur.autoresizingMask = [.width, .height]

            let host = ClickThroughHostingView(rootView: PrivacyOverlayView(guardState: guardState, isPrimary: screen == NSScreen.main))
            host.frame = blur.bounds
            host.autoresizingMask = [.width, .height]
            blur.addSubview(host)

            panel.contentView = blur
            panel.setFrame(screen.frame, display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                panel.animator().alphaValue = 1
            }
            panels.append(panel)
        }
    }

    func hide() {
        let closing = panels
        panels = []
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            for p in closing { p.animator().alphaValue = 0 }
        }, completionHandler: {
            for p in closing { p.orderOut(nil) }
        })
    }

    private func hideNow() {
        for p in panels { p.orderOut(nil) }
        panels = []
    }
}

struct PrivacyOverlayView: View {
    let guardState: PrivacyGuard
    let isPrimary: Bool
    @State private var shown = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.38)
            if isPrimary { column } else {
                Image(systemName: "eye.slash").font(.system(size: 48, weight: .light)).foregroundStyle(.white.opacity(0.45))
            }
        }
        .environment(\.colorScheme, .dark)
        .onAppear { withAnimation(DS.Motion.overlayIn) { shown = true } }
    }

    private var column: some View {
        VStack(spacing: 28) {
            VStack(spacing: 12) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(.white)
                    .symbolEffect(.bounce, value: shown)
                Text("Privacy Guard is on")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
                if let since = guardState.since {
                    TimelineView(.periodic(from: since, by: 1)) { ctx in
                        Text("for \(Duration.seconds(ctx.date.timeIntervalSince(since)).formatted(.time(pattern: .minuteSecond)))")
                            .font(.title3).monospacedDigit()
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            VStack(spacing: 0) {
                row(micSymbol, micText, micTone)
                Divider().overlay(Color.white.opacity(0.12))
                row(cameraSymbol, cameraText, cameraTone)
                Divider().overlay(Color.white.opacity(0.12))
                row("rectangle.on.rectangle.slash", "Every screen is hidden", .done)
            }
            .frame(width: 420)
            .floatingGlass(cornerRadius: 18)
            Text("Tap your Privacy Guard zone again, or click anywhere, to come back.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.6))
        }
        .opacity(shown ? 1 : 0)
        .scaleEffect(shown ? 1 : 0.97)
    }

    private enum Tone { case done, working, warn, neutral }

    private func row(_ symbol: String, _ text: String, _ tone: Tone) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 26)
                .foregroundStyle(.white.opacity(0.9))
            Text(text)
                .font(.body)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
            switch tone {
            case .done: Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(.green)
            case .working: ProgressView().controlSize(.small)
            case .warn: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .neutral: Image(systemName: "minus").foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
    }

    private var micSymbol: String { guardState.mic == .skipped ? "mic" : "mic.slash" }

    private var micText: String {
        switch guardState.mic {
        case .muted(let n): n == 1 ? "Microphone muted" : "\(n) microphones muted"
        case .unavailable: "Couldn't mute the microphone"
        case .skipped: "Microphone left on (your setting)"
        case .idle: "Muting the microphone…"
        }
    }

    private var micTone: Tone {
        switch guardState.mic {
        case .muted: .done
        case .unavailable: .warn
        case .skipped: .neutral
        case .idle: .working
        }
    }

    private var cameraSymbol: String { guardState.camera == .notInUse || guardState.camera == .skipped ? "video" : "video.slash" }

    private var cameraText: String {
        switch guardState.camera {
        case .checking, .idle: "Checking the camera…"
        case .notInUse: "Camera isn't in use"
        case .turnedOff(let app): "Camera turned off in \(app)"
        case .stillOn(let app): app.map { "Camera may still be on in \($0)" } ?? "Camera is on in an app LidTap can't control"
        case .needsAccessibility: "Camera is on. Allow Accessibility so LidTap can turn it off"
        case .skipped: "Camera left alone (your setting)"
        }
    }

    private var cameraTone: Tone {
        switch guardState.camera {
        case .checking, .idle: .working
        case .notInUse, .turnedOff: .done
        case .stillOn, .needsAccessibility: .warn
        case .skipped: .neutral
        }
    }
}
