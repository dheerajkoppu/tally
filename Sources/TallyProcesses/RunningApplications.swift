import AppKit

/// The apps LaunchServices knows about: which pids are regular (Dock) apps, and the names macOS gives
/// helper processes ("Safari Web Content", "OpenLogi Agent").
///
/// Reading NSRunningApplication properties costs a LaunchServices round trip per app, so the list is read again
/// only after an app launches or quits, an unknown app comes to the front, or five minutes pass.
/// NSRunningApplication's properties are atomic and safe to read off the main thread.
final class RunningApplications {
    private struct Entry {
        var name: String?
        var executableName: String?
        var isRegular: Bool
    }

    private static let fallbackRefreshNanoseconds: UInt64 = 300_000_000_000

    private let lock = NSLock()
    private var isStale = true
    private var regularPids = Set<Int32>()
    private var entries: [Int32: Entry] = [:]
    private var lastRefreshNanoseconds: UInt64 = 0
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in self?.markStale() })
        }
        // An accessory app that opens a window becomes a regular app without launching again.
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { [weak self] notification in
            guard let self, let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = application.processIdentifier
            lock.lock()
            let isKnown = regularPids.contains(pid)
            lock.unlock()
            if !isKnown { markStale() }
        })
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
    }

    private func markStale() {
        lock.lock()
        isStale = true
        lock.unlock()
    }

    func refreshIfNeeded(now: UInt64) {
        lock.lock()
        let isDue = isStale || lastRefreshNanoseconds == 0 || now &- lastRefreshNanoseconds >= Self.fallbackRefreshNanoseconds
        isStale = false
        lock.unlock()
        guard isDue else { return }
        lastRefreshNanoseconds = now

        var refreshed: [Int32: Entry] = [:]
        var regular = Set<Int32>()
        for application in NSWorkspace.shared.runningApplications {
            let pid = application.processIdentifier
            guard pid > 0 else { continue }
            let isRegular = application.activationPolicy == .regular
            refreshed[pid] = Entry(name: application.localizedName, executableName: application.executableURL?.lastPathComponent, isRegular: isRegular)
            if isRegular { regular.insert(pid) }
        }
        lock.lock()
        entries = refreshed
        regularPids = regular
        lock.unlock()
    }

    /// Checks the executable too, so a reused pid never borrows another app's identity.
    func isRegular(pid: Int32, executableName: String?) -> Bool {
        guard let entry = entries[pid], matches(entry, executableName) else { return false }
        return entry.isRegular
    }

    func localizedName(pid: Int32, executableName: String?) -> String? {
        guard let entry = entries[pid], matches(entry, executableName), let name = entry.name, !name.isEmpty else { return nil }
        return name
    }

    /// Compares file names only: LaunchServices and the kernel can report different paths to the same
    /// binary (a cryptex path against its /System alias).
    private func matches(_ entry: Entry, _ executableName: String?) -> Bool {
        guard let expected = entry.executableName, let executableName else { return true }
        return expected == executableName
    }
}
