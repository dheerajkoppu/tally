import AppKit

/// Something the user asked to quit, waiting for confirmation.
public struct QuitRequest: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var message: String
    public var pids: [Int32]
    /// The app's main pid, quit through NSRunningApplication so it can save its work.
    public var appPid: Int32?
    /// When each process started, so a pid that a new process takes over while the confirmation is open is left alone.
    public var startDates: [Int32: Date]

    /// Pids missing from `startDates` are looked up now.
    public init(id: String, title: String, message: String, pids: [Int32], appPid: Int32?, startDates: [Int32: Date]? = nil) {
        self.id = id
        self.title = title
        self.message = message
        self.pids = pids
        self.appPid = appPid
        var dates = startDates ?? [:]
        for pid in pids + [appPid].compactMap({ $0 }) where dates[pid] == nil {
            dates[pid] = ProcessActions.startDate(of: pid)
        }
        self.startDates = dates
    }

    public static func app(_ app: AppUsage) -> QuitRequest {
        let count = app.processCount
        let message = count == 1 ? "1 process will close." : "\(count) processes will close."
        return QuitRequest(id: app.id, title: "Quit \(app.name)?", message: message, pids: app.processes.map(\.pid), appPid: app.kind == .app ? app.mainPid : nil, startDates: startDates(of: app.processes))
    }

    public static func process(_ process: ProcessSample) -> QuitRequest {
        QuitRequest(id: "pid-\(process.pid)", title: "Quit \(process.name)?", message: "Process \(process.pid) will close.", pids: [process.pid], appPid: nil, startDates: startDates(of: [process]))
    }

    private static func startDates(of processes: [ProcessSample]) -> [Int32: Date] {
        var dates: [Int32: Date] = [:]
        for process in processes {
            if let startDate = process.startDate { dates[process.pid] = startDate }
        }
        return dates
    }
}

public enum ProcessActions {
    /// Ask politely: NSRunningApplication.terminate for apps, SIGTERM for processes.
    public static func quit(_ request: QuitRequest) {
        if let appPid = request.appPid, isOriginal(appPid, of: request), let running = NSRunningApplication(processIdentifier: appPid) {
            running.terminate()
            return
        }
        for pid in request.pids where isOriginal(pid, of: request) { kill(pid, SIGTERM) }
    }

    /// End immediately, without letting the app save.
    public static func forceQuit(_ request: QuitRequest) {
        if let appPid = request.appPid, isOriginal(appPid, of: request), let running = NSRunningApplication(processIdentifier: appPid) {
            running.forceTerminate()
        }
        for pid in request.pids where isOriginal(pid, of: request) { kill(pid, SIGKILL) }
    }

    /// Only a real process (never launchd, the kernel or a process group) that is still the one the request was made for.
    static func isOriginal(_ pid: Int32, of request: QuitRequest) -> Bool {
        guard pid > 1, let expected = request.startDates[pid], let current = startDate(of: pid) else { return false }
        return abs(current.timeIntervalSince(expected)) < 0.001
    }

    /// The kernel's start time for a live process, computed as the process samplers compute it.
    static func startDate(of pid: Int32) -> Date? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size >= MemoryLayout<kinfo_proc>.stride,
              info.kp_proc.p_pid == pid, info.kp_proc.p_stat != CChar(SZOMB) else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        let microseconds = UInt64(max(0, start.tv_sec)) * 1_000_000 + UInt64(max(0, start.tv_usec))
        return Date(timeIntervalSince1970: Double(microseconds) / 1_000_000)
    }
}
