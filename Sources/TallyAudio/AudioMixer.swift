import AppKit
import Combine
import Foundation
import TallyCore

/// Per-app volume control. Lists the apps playing sound and changes their level with Core Audio process taps.
/// Nothing is recorded or written to disk: tapped audio goes straight back out to the speakers.
@MainActor
public final class AudioMixer: ObservableObject {
    public static let shared = AudioMixer()

    /// Apps playing sound now or a few seconds ago, plus any whose level was changed. Sorted by name.
    @Published public private(set) var apps: [AudioApp] = []
    @Published public private(set) var permission: AudioCapturePermission
    @Published public private(set) var isRequestingPermission = false
    /// The current output device, e.g. "MacBook Pro Speakers".
    @Published public private(set) var outputDeviceName: String?

    private let controller = AudioTapController()
    private var settings: [String: VolumeSetting] = [:]
    private var visibleCount = 0
    private var refreshTimer: Timer?
    private var terminationObserver: NSObjectProtocol?
    private var isPermissionOverridden = false
    private var lastDiscovery = Date.distantPast

    private init() {
        permission = AudioCaptureAccess.status()
        controller.onDiscovery = { [weak self] discovery in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receive(discovery) }
            }
        }
        controller.installListeners()
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
        refreshNow(waitingUpTo: 0.3)
    }

    /// Sliders work unless macOS has refused audio capture.
    public var canAdjust: Bool { permission != .denied }

    /// True when any listed app is turned down or muted.
    public var hasAdjustments: Bool { apps.contains { $0.isAdjusted } }

    /// Call when the mixer becomes visible: refreshes now and every 2 seconds until `stop`.
    public func start() {
        visibleCount += 1
        controller.installListeners()
        updatePermission(AudioCaptureAccess.status())
        if Date().timeIntervalSince(lastDiscovery) > 2.5 {
            refreshNow(waitingUpTo: 0.15)
        } else {
            controller.refresh()
        }
        guard refreshTimer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.controller.refresh() }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    public func stop() {
        visibleCount = max(0, visibleCount - 1)
        guard visibleCount == 0 else { return }
        refreshTimer?.invalidate()
        refreshTimer = nil
        if !hasAdjustments { controller.removeProcessListener() }
    }

    public func volume(for appID: String) -> Double {
        settings[appID]?.volume ?? 1
    }

    public func isMuted(_ appID: String) -> Bool {
        settings[appID]?.isMuted ?? false
    }

    /// 0...1. Values within a hair of the top snap to 100%, which hands the app back to macOS untouched.
    public func setVolume(_ volume: Double, for appID: String) {
        let clamped = min(max(volume.isFinite ? volume : 1, 0), 1)
        var setting = settings[appID] ?? VolumeSetting()
        setting.volume = clamped > 0.985 ? 1 : clamped
        update(setting, for: appID)
    }

    public func setMuted(_ muted: Bool, for appID: String) {
        var setting = settings[appID] ?? VolumeSetting()
        setting.isMuted = muted
        update(setting, for: appID)
    }

    public func toggleMute(for appID: String) {
        setMuted(!isMuted(appID), for: appID)
    }

    /// Puts every app back to full volume, unmuted.
    public func resetAll() {
        settings.removeAll()
        apps = apps.map { app in
            var app = app
            app.volume = 1
            app.isMuted = false
            app.problem = nil
            return app
        }
        pushSettings()
    }

    /// Shows the system prompt for audio capture if the user has not answered it yet.
    public func requestPermission() {
        guard !isRequestingPermission else { return }
        isRequestingPermission = true
        AudioCaptureAccess.request { granted in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let mixer = AudioMixer.shared
                    mixer.isRequestingPermission = false
                    mixer.updatePermission(granted ? .authorized : .denied)
                }
            }
        }
    }

    /// Opens System Settings at Privacy & Security › Screen & System Audio Recording.
    public func openPrivacySettings() {
        NSWorkspace.shared.open(AudioCaptureAccess.settingsURL)
    }

    /// Treats audio capture as allowed without asking, for probes run from a terminal. macOS still decides
    /// when the tap starts, and hands back silence if it refuses.
    public func assumeAudioCaptureAllowed() {
        isPermissionOverridden = true
        permission = .authorized
        pushSettings()
    }

    /// Removes every tap right away. Runs automatically when the app terminates.
    public func shutdown() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        controller.shutdown()
    }

    /// The live state of each tap, for probes.
    public func diagnostics() async -> [AudioTapDiagnostics] {
        await withCheckedContinuation { continuation in
            controller.diagnostics { continuation.resume(returning: $0) }
        }
    }

    private func update(_ setting: VolumeSetting, for appID: String) {
        settings[appID] = setting.isAdjusted ? setting : nil
        if let index = apps.firstIndex(where: { $0.id == appID }) {
            apps[index].volume = setting.volume
            apps[index].isMuted = setting.isMuted
            apps[index].problem = nil
        }
        if setting.isAdjusted, permission == .unknown, AudioCaptureAccess.canAsk {
            requestPermission()
        }
        pushSettings()
    }

    private func updatePermission(_ newValue: AudioCapturePermission) {
        guard !isPermissionOverridden, newValue != permission else { return }
        permission = newValue
        if newValue == .denied { resetAll() } else { pushSettings() }
    }

    private func pushSettings() {
        let allowed = permission == .authorized || (permission == .unknown && !AudioCaptureAccess.canAsk)
        controller.apply(settings: settings, tappingAllowed: allowed)
    }

    /// Waits briefly for a fresh list so a popover opens with its rows already in place.
    private func refreshNow(waitingUpTo timeout: TimeInterval) {
        let semaphore = DispatchSemaphore(value: 0)
        let result = DiscoveryResult()
        controller.refresh { discovery in
            result.discovery = discovery
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeout) == .success, let discovery = result.discovery {
            receive(discovery)
        }
    }

    private func receive(_ discovery: AudioDiscovery) {
        lastDiscovery = Date()
        let merged = discovery.apps.map { app in
            var app = app
            let setting = settings[app.id] ?? VolumeSetting()
            app.volume = setting.volume
            app.isMuted = setting.isMuted
            return app
        }
        if merged != apps { apps = merged }
        if discovery.outputDeviceName != outputDeviceName { outputDeviceName = discovery.outputDeviceName }
    }
}

private final class DiscoveryResult: @unchecked Sendable {
    var discovery: AudioDiscovery?
}
