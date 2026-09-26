import Darwin
import Foundation

/// A process instance: the pid plus its start time, so a reused pid never inherits another process's counters.
struct ProcessKey: Hashable {
    var pid: Int32
    var startMicroseconds: UInt64
}

/// Converts mach absolute time, the unit of `rusage` CPU times, into nanoseconds.
enum MachClock {
    static let nanosecondsPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        guard timebase.denom != 0 else { return 1 }
        return Double(timebase.numer) / Double(timebase.denom)
    }()

    static func nanoseconds(fromTicks ticks: UInt64) -> Double {
        Double(ticks) * nanosecondsPerTick
    }

    static func nowNanoseconds() -> UInt64 {
        UInt64(Double(mach_absolute_time()) * nanosecondsPerTick)
    }
}

/// The kernel's 16-byte short name as two words, compared without building a string.
struct CommandName: Hashable {
    var head: UInt64
    var tail: UInt64

    var string: String {
        withUnsafeBytes(of: self) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
    }
}

struct ProcessIdentity {
    var pid: Int32
    var parentPid: Int32
    var uid: UInt32
    /// The kernel's short name, used only when the executable path is unknown.
    var command: CommandName
    var startMicroseconds: UInt64
    var isZombie: Bool

    var startDate: Date? {
        startMicroseconds == 0 ? nil : Date(timeIntervalSince1970: Double(startMicroseconds) / 1_000_000)
    }
}

enum UsageReadResult {
    case usage(rusage_info_v6)
    case denied
    case gone
}

/// Every process from one sysctl, including other users' processes that libproc will not describe.
/// Keeps its buffer between calls. Not thread-safe; the owner serializes access.
final class ProcessTable {
    private var buffer: [kinfo_proc] = []

    func read() -> [ProcessIdentity] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        let stride = MemoryLayout<kinfo_proc>.stride
        for _ in 0..<3 {
            var length = 0
            guard sysctl(&mib, 3, nil, &length, nil, 0) == 0, length > 0 else { return [] }
            let needed = length / stride + 64
            if buffer.count < needed { buffer = [kinfo_proc](repeating: kinfo_proc(), count: needed + 128) }
            length = buffer.count * stride
            let result = buffer.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &length, nil, 0) }
            if result != 0 {
                if errno == ENOMEM {
                    buffer = []
                    continue
                }
                return []
            }
            let count = length / stride
            var identities: [ProcessIdentity] = []
            identities.reserveCapacity(count)
            for index in 0..<count {
                let info = buffer[index]
                let start = info.kp_proc.p_un.__p_starttime
                identities.append(ProcessIdentity(
                    pid: info.kp_proc.p_pid,
                    parentPid: info.kp_eproc.e_ppid,
                    uid: info.kp_eproc.e_ucred.cr_uid,
                    command: withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
                        CommandName(head: raw.loadUnaligned(fromByteOffset: 0, as: UInt64.self), tail: raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self))
                    },
                    startMicroseconds: UInt64(max(0, start.tv_sec)) * 1_000_000 + UInt64(max(0, start.tv_usec)),
                    isZombie: info.kp_proc.p_stat == CChar(SZOMB)
                ))
            }
            return identities
        }
        return []
    }
}

/// Thin wrappers over sysctl and libproc.
enum ProcessInfoReader {
    static func usage(of pid: Int32) -> UsageReadResult {
        var usage = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        }
        if result == 0 { return .usage(usage) }
        return errno == ESRCH ? .gone : .denied
    }

    static func threadCount(of pid: Int32) -> Int? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        return Int(info.pti_threadnum)
    }

    static func executablePath(of pid: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        if length > 0 { return String(decoding: buffer.prefix(Int(length)), as: UTF8.self) }
        return execPath(of: pid)
    }

    /// The path the process was started with, for binaries proc_pidpath cannot resolve (replaced on disk by an upgrade).
    private static func execPath(of pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var length = 0
        guard sysctl(&mib, 3, nil, &length, nil, 0) == 0, length > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 3, &buffer, &length, nil, 0) == 0, length > MemoryLayout<Int32>.size else { return nil }
        let pathBytes = buffer[MemoryLayout<Int32>.size..<length].prefix { $0 != 0 }
        let path = String(decoding: pathBytes, as: UTF8.self)
        return path.hasPrefix("/") ? path : nil
    }

    private typealias ResponsibilityFunction = @convention(c) (pid_t) -> pid_t

    private static let responsibilityFunction: ResponsibilityFunction? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsibilityFunction.self)
    }()

    /// The process macOS holds responsible for `pid`, or nil when it cannot tell (other users' processes).
    static func responsiblePid(of pid: Int32) -> Int32? {
        guard let function = responsibilityFunction else { return nil }
        let responsible = function(pid)
        return responsible > 0 ? responsible : nil
    }
}
