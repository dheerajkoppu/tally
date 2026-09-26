import CoreAudio
import Foundation

/// What the controller found, handed to the main thread.
struct AudioDiscovery: Sendable {
    var apps: [AudioApp]
    var outputDeviceName: String?
}

/// Discovers which processes play sound and keeps one process tap per app whose level the user changed.
/// Every Core Audio call happens on `queue`.
final class AudioTapController: @unchecked Sendable {
    let queue = DispatchQueue(label: "tally.audio", qos: .userInitiated)

    /// Called on `queue` after each refresh.
    var onDiscovery: ((AudioDiscovery) -> Void)?

    private struct ProcessEntry {
        var pid: pid_t
        var owner: AudioOwner?
        var isRunningOutput: Bool
    }

    private struct AppGroup {
        var owner: AudioOwner
        var objectIDs: [AudioObjectID] = []
        var pids: Set<pid_t> = []
        var isPlaying = false
    }

    /// How long an app stays in the list after it stops playing, so rows do not flicker between tracks.
    private static let lingerInterval: TimeInterval = 10
    /// How long a tap stays at full volume before it is removed, so dragging through 100% does not rebuild it.
    private static let teardownDelay: TimeInterval = 1.5
    /// How long a tap outlives its app's last process, so an app that restarts its audio process keeps its level.
    private static let vanishGrace: TimeInterval = 5

    private let ownPid = getpid()
    private var processes: [AudioObjectID: ProcessEntry] = [:]
    private var groups: [String: AppGroup] = [:]
    private var lastPlayed: [String: Date] = [:]
    private var settings: [String: VolumeSetting] = [:]
    private var taps: [String: ProcessTap] = [:]
    private var failures: [String: String] = [:]
    private var restoredAt: [String: Date] = [:]
    private var vanishedAt: [String: Date] = [:]
    private var tappingAllowed = false
    private var outputDeviceID: AudioObjectID?
    private var listenersInstalled = false
    private var isShutDown = false
    private var processListListener: AudioObjectPropertyListenerBlock?

    init() {}

    func installListeners() {
        queue.async { self.installListenersOnQueue() }
    }

    func refresh(completion: ((AudioDiscovery) -> Void)? = nil) {
        queue.async {
            let discovery = self.discover()
            completion?(discovery)
        }
    }

    func apply(settings newSettings: [String: VolumeSetting], tappingAllowed allowed: Bool) {
        queue.async {
            let changed = newSettings.filter { self.settings[$0.key] != $0.value }.keys
            for appID in changed { self.failures[appID] = nil }
            self.settings = newSettings
            self.tappingAllowed = allowed
            self.synchronizeTaps()
            self.publish()
        }
    }

    func diagnostics(_ completion: @escaping ([AudioTapDiagnostics]) -> Void) {
        queue.async {
            completion(self.taps.values.map(\.diagnostics).sorted { $0.appID < $1.appID })
        }
    }

    /// Removes every tap and waits for it, so apps play normally after Tally quits.
    func shutdown() {
        queue.sync {
            isShutDown = true
            for tap in taps.values { tap.invalidate() }
            taps.removeAll()
        }
    }

    /// Stops following audio processes while the mixer is closed and no app is turned down.
    func removeProcessListener() {
        queue.async {
            guard let listener = self.processListListener, self.taps.isEmpty else { return }
            var processListAddress = AudioProperty.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(AudioProperty.systemObject, &processListAddress, self.queue, listener)
            self.processListListener = nil
        }
    }

    private func installProcessListenerOnQueue() {
        guard processListListener == nil else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            _ = self.discover()
        }
        var processListAddress = AudioProperty.address(kAudioHardwarePropertyProcessObjectList)
        if AudioObjectAddPropertyListenerBlock(AudioProperty.systemObject, &processListAddress, queue, listener) == noErr {
            processListListener = listener
        }
    }

    private func installListenersOnQueue() {
        installProcessListenerOnQueue()
        guard !listenersInstalled else { return }
        listenersInstalled = true
        var outputAddress = AudioProperty.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioProperty.systemObject, &outputAddress, queue) { [weak self] _, _ in
            self?.defaultOutputChanged()
        }
        outputDeviceID = AudioProperty.defaultOutputDevice()
    }

    private func defaultOutputChanged() {
        let newDevice = AudioProperty.defaultOutputDevice()
        guard newDevice != outputDeviceID else { return }
        outputDeviceID = newDevice
        for tap in taps.values { tap.invalidate() }
        taps.removeAll()
        failures.removeAll()
        synchronizeTaps()
        publish()
    }

    @discardableResult
    private func discover() -> AudioDiscovery {
        if outputDeviceID == nil { outputDeviceID = AudioProperty.defaultOutputDevice() }
        let objectIDs = AudioProperty.array(AudioProperty.systemObject, kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self)
        var nextProcesses: [AudioObjectID: ProcessEntry] = [:]
        for objectID in objectIDs {
            var entry: ProcessEntry
            if let known = processes[objectID] {
                entry = known
            } else {
                let pid = AudioProperty.value(objectID, kAudioProcessPropertyPID, initial: pid_t(-1)) ?? -1
                var owner: AudioOwner?
                if pid > 0, pid != ownPid {
                    owner = AudioOwnerResolver.owner(pid: pid, bundleIdentifier: AudioProperty.string(objectID, kAudioProcessPropertyBundleID))
                }
                entry = ProcessEntry(pid: pid, owner: owner, isRunningOutput: false)
            }
            if entry.owner != nil {
                entry.isRunningOutput = (AudioProperty.value(objectID, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) ?? 0) != 0
            }
            nextProcesses[objectID] = entry
        }
        processes = nextProcesses

        var nextGroups: [String: AppGroup] = [:]
        for (objectID, entry) in nextProcesses {
            guard let owner = entry.owner else { continue }
            var group = nextGroups[owner.id] ?? AppGroup(owner: owner)
            group.objectIDs.append(objectID)
            group.pids.insert(entry.pid)
            group.isPlaying = group.isPlaying || entry.isRunningOutput
            nextGroups[owner.id] = group
        }
        for key in nextGroups.keys { nextGroups[key]?.objectIDs.sort() }
        groups = nextGroups

        let now = Date()
        for group in nextGroups.values where group.isPlaying { lastPlayed[group.owner.id] = now }
        lastPlayed = lastPlayed.filter { nextGroups[$0.key] != nil }

        synchronizeTaps()
        return publish()
    }

    @discardableResult
    private func publish() -> AudioDiscovery {
        let now = Date()
        let visible = groups.values.filter { group in
            let id = group.owner.id
            if group.isPlaying || taps[id] != nil || settings[id]?.isAdjusted == true { return true }
            if let played = lastPlayed[id], now.timeIntervalSince(played) < Self.lingerInterval { return true }
            return false
        }
        let apps: [AudioApp] = visible.map { group -> AudioApp in
            let setting = settings[group.owner.id] ?? VolumeSetting()
            return AudioApp(
                id: group.owner.id,
                name: group.owner.name,
                bundleIdentifier: group.owner.bundleIdentifier,
                iconPath: group.owner.iconPath,
                pids: group.pids.sorted(),
                isPlaying: group.isPlaying,
                volume: setting.volume,
                isMuted: setting.isMuted,
                isTapped: taps[group.owner.id] != nil,
                problem: failures[group.owner.id]
            )
        }
        .sorted { (lhs: AudioApp, rhs: AudioApp) in lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
        let deviceName = outputDeviceID.flatMap { AudioProperty.string($0, kAudioObjectPropertyName) }
        let discovery = AudioDiscovery(apps: apps, outputDeviceName: deviceName)
        onDiscovery?(discovery)
        return discovery
    }

    private func scheduleSynchronize(after delay: TimeInterval) {
        queue.asyncAfter(deadline: .now() + delay + 0.05) { [weak self] in
            guard let self, !self.isShutDown else { return }
            self.synchronizeTaps()
            self.publish()
        }
    }

    private func synchronizeTaps() {
        guard !isShutDown else { return }
        let now = Date()
        for (appID, tap) in taps {
            let setting = settings[appID] ?? VolumeSetting()
            let group = groups[appID]
            var keep = tappingAllowed && tap.outputDeviceID == outputDeviceID
            if group == nil {
                if let vanished = vanishedAt[appID] {
                    keep = keep && now.timeIntervalSince(vanished) < Self.vanishGrace
                } else {
                    vanishedAt[appID] = now
                    scheduleSynchronize(after: Self.vanishGrace)
                }
            } else {
                vanishedAt[appID] = nil
            }
            if keep, !setting.isAdjusted {
                if let restored = restoredAt[appID] {
                    keep = now.timeIntervalSince(restored) < Self.teardownDelay
                } else {
                    restoredAt[appID] = now
                    scheduleSynchronize(after: Self.teardownDelay)
                }
            } else {
                restoredAt[appID] = nil
            }
            if keep, let group, group.objectIDs != tap.processObjectIDs, !tap.update(processObjectIDs: group.objectIDs) {
                keep = false
            }
            if keep {
                tap.renderer.gain = setting.gain
            } else {
                tap.invalidate()
                taps[appID] = nil
                restoredAt[appID] = nil
                vanishedAt[appID] = nil
            }
        }

        guard tappingAllowed, let outputDeviceID else { return }
        for (appID, setting) in settings where setting.isAdjusted && taps[appID] == nil && failures[appID] == nil {
            guard let group = groups[appID], !group.objectIDs.isEmpty else { continue }
            do {
                taps[appID] = try ProcessTap(appID: appID, name: group.owner.name, processObjectIDs: group.objectIDs, outputDeviceID: outputDeviceID, gain: setting.gain)
            } catch {
                failures[appID] = "Could not change the volume: \(error)"
            }
        }
    }
}
