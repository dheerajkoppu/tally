import Foundation
import IOKit
import TallyCore

/// Disk throughput from IOKit block storage statistics, and capacity of the mounted volumes.
final class DiskReader {
    private struct DriveCounters {
        var bytesRead: UInt64
        var bytesWritten: UInt64
    }

    private struct VolumeState {
        var volumes: [VolumeInfo] = []
        var refreshedAt: TimeInterval = -.infinity
        var isRefreshing = false
        var mountCount: Int32 = -1
    }

    /// Reading free space ("important usage") asks the cache-delete service and takes ~15 ms, so volumes refresh
    /// in the background on this interval instead of on every sample, and rarely while nothing shows them.
    /// A drive plugged in or ejected refreshes them on the next sample either way.
    private static let volumeRefreshVisible: TimeInterval = 30
    private static let volumeRefreshHidden: TimeInterval = 300

    /// Set by the owner before each sample.
    var isVisible = false

    private var previousCounters: [UInt64: DriveCounters] = [:]
    private var previousTime: TimeInterval = 0
    private var virtualDrives: [UInt64: Bool] = [:]
    private var lastRates: (read: Double, write: Double) = (0, 0)

    private let volumeLock = NSLock()
    private var volumeState = VolumeState()
    private let volumeQueue = DispatchQueue(label: "tally.system.volumes", qos: .background)
    private var diskImageDevices: [String: Bool] = [:]
    /// Purgeable bytes per mount path (important-usage capacity minus plain available capacity) and when they were read.
    /// Reading them asks the cache-delete service, so they are read again only every `volumeRefreshHidden`.
    private var purgeable: [String: (bytes: Int, readAt: TimeInterval)] = [:]

    init() {
        previousCounters = readCounters()
        previousTime = MonotonicClock.now()
        refreshVolumesInBackground()
    }

    func read() -> DiskStats {
        var stats = DiskStats()

        let now = MonotonicClock.now()
        let elapsed = now - previousTime
        if elapsed >= 0.1 {
            let current = readCounters()
            var readDelta: UInt64 = 0
            var writeDelta: UInt64 = 0
            for (identifier, counters) in current {
                guard let previous = previousCounters[identifier] else { continue }
                if counters.bytesRead >= previous.bytesRead { readDelta += counters.bytesRead - previous.bytesRead }
                if counters.bytesWritten >= previous.bytesWritten { writeDelta += counters.bytesWritten - previous.bytesWritten }
            }
            previousCounters = current
            previousTime = now
            lastRates = (Double(readDelta) / elapsed, Double(writeDelta) / elapsed)
        }
        stats.readBytesPerSecond = lastRates.read
        stats.writeBytesPerSecond = lastRates.write

        let volumes = currentVolumes(now: now)
        stats.volumes = volumes
        if let root = volumes.first(where: \.isRoot) {
            stats.totalBytes = root.totalBytes
            stats.freeBytes = root.freeBytes
        }
        return stats
    }

    private func readCounters() -> [UInt64: DriveCounters] {
        var counters: [UInt64: DriveCounters] = [:]
        IORegistry.forEachService(matching: "IOBlockStorageDriver") { driver in
            let identifier = IORegistry.entryID(driver)
            if isVirtualDrive(driver, identifier: identifier) { return }
            guard let statistics = IORegistry.property(driver, "Statistics") as? [String: Any] else { return }
            counters[identifier] = DriveCounters(
                bytesRead: RegistryValue.uint64(statistics["Bytes (Read)"]) ?? 0,
                bytesWritten: RegistryValue.uint64(statistics["Bytes (Write)"]) ?? 0
            )
        }
        return counters
    }

    /// Disk images count their traffic twice (once on the image, once on the drive holding the file), so skip them.
    private func isVirtualDrive(_ driver: io_registry_entry_t, identifier: UInt64) -> Bool {
        if let known = virtualDrives[identifier] { return known }
        let isVirtual = Self.isVirtualInterconnect(driver)
        virtualDrives[identifier] = isVirtual
        return isVirtual
    }

    private static func isVirtualInterconnect(_ entry: io_registry_entry_t) -> Bool {
        guard let characteristics = IORegistry.searchParents(entry, "Protocol Characteristics") as? [String: Any] else { return false }
        return (characteristics["Physical Interconnect"] as? String) == "Virtual Interface"
    }

    private func currentVolumes(now: TimeInterval) -> [VolumeInfo] {
        // A cheap count of mounted file systems, so a drive plugged in or ejected shows up on the next sample.
        let mountCount = getfsstat(nil, 0, MNT_NOWAIT)
        volumeLock.lock()
        let state = volumeState
        volumeLock.unlock()

        if state.refreshedAt == -.infinity {
            volumeQueue.sync {
                if self.isAwaitingFirstVolumes { refreshVolumes() }
            }
        } else if now - state.refreshedAt >= (isVisible ? Self.volumeRefreshVisible : Self.volumeRefreshHidden) || mountCount != state.mountCount {
            refreshVolumesInBackground()
        }

        volumeLock.lock()
        defer { volumeLock.unlock() }
        return volumeState.volumes
    }

    private func refreshVolumesInBackground() {
        volumeLock.lock()
        if volumeState.isRefreshing {
            volumeLock.unlock()
            return
        }
        volumeState.isRefreshing = true
        volumeLock.unlock()
        volumeQueue.async { [weak self] in self?.refreshVolumes() }
    }

    private var isAwaitingFirstVolumes: Bool {
        volumeLock.lock()
        defer { volumeLock.unlock() }
        return volumeState.refreshedAt == -.infinity
    }

    private func refreshVolumes() {
        let mountCount = getfsstat(nil, 0, MNT_NOWAIT)
        let volumes = listVolumes()
        volumeLock.lock()
        volumeState.volumes = volumes
        volumeState.mountCount = mountCount
        volumeState.refreshedAt = MonotonicClock.now()
        volumeState.isRefreshing = false
        volumeLock.unlock()
    }

    private func listVolumes() -> [VolumeInfo] {
        let keys: Set<URLResourceKey> = [
            .volumeLocalizedNameKey, .volumeIsLocalKey, .volumeIsBrowsableKey, .volumeIsRootFileSystemKey,
            .volumeIsInternalKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        ]
        let now = MonotonicClock.now()
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []
        var volumes: [VolumeInfo] = []
        var mountedDevices = Set<String>()
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            let path = url.path
            let isRoot = values.volumeIsRootFileSystem ?? (path == "/")
            guard values.volumeIsLocal ?? false, values.volumeIsBrowsable ?? true else { continue }
            if !isRoot && (path.hasPrefix("/System/Volumes/") || path.hasPrefix("/private/")) { continue }
            if !isRoot && isDiskImage(mountPath: path, mountedDevices: &mountedDevices) { continue }
            guard let total = values.volumeTotalCapacity, total > 0 else { continue }
            let plainAvailable = values.volumeAvailableCapacity ?? 0
            if purgeable[path].map({ now - $0.readAt >= Self.volumeRefreshHidden }) ?? true {
                let important = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
                purgeable[path] = (important.map { Int($0) - plainAvailable } ?? 0, now)
            }
            let available = plainAvailable + (purgeable[path]?.bytes ?? 0)
            let name = values.volumeLocalizedName ?? FileManager.default.displayName(atPath: path)
            volumes.append(VolumeInfo(
                name: name,
                mountPath: path,
                totalBytes: UInt64(total),
                freeBytes: UInt64(max(0, min(available, total))),
                isInternal: values.volumeIsInternal ?? isRoot,
                isRoot: isRoot
            ))
        }
        // The next drive or image attached reuses a device name, so answers for unmounted ones are dropped.
        diskImageDevices = diskImageDevices.filter { mountedDevices.contains($0.key) }
        purgeable = purgeable.filter { entry in volumes.contains { $0.mountPath == entry.key } }
        return volumes.sorted { lhs, rhs in
            if lhs.isRoot != rhs.isRoot { return lhs.isRoot }
            if lhs.isInternal != rhs.isInternal { return lhs.isInternal }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// Mounted .dmg files (installers, simulator runtimes) are not drives.
    private func isDiskImage(mountPath: String, mountedDevices: inout Set<String>) -> Bool {
        var fileSystem = statfs()
        guard statfs(mountPath, &fileSystem) == 0 else { return false }
        let device = withUnsafeBytes(of: fileSystem.f_mntfromname) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
        guard device.hasPrefix("/dev/") else { return false }
        let bsdName = String(device.dropFirst("/dev/".count))
        mountedDevices.insert(bsdName)
        if let known = diskImageDevices[bsdName] { return known }
        var isImage = false
        let media = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, bsdName))
        if media != 0 {
            isImage = Self.isVirtualInterconnect(media)
            IOObjectRelease(media)
        }
        diskImageDevices[bsdName] = isImage
        return isImage
    }
}
