import Foundation

/// CPU time, resident memory and thread count for processes owned by other users.
/// libproc refuses those with EPERM; /bin/ps is setuid root and can still read them.
struct RestrictedFigures {
    var cpuSeconds: Double
    var residentBytes: UInt64
    var threadCount: Int?
}

enum RestrictedProcessReader {
    static let isAvailable = FileManager.default.isExecutableFile(atPath: "/bin/ps")

    /// One `ps` run for the given pids. With `countingThreads`, ps lists every thread, which costs about twice as much.
    static func read(pids: [Int32], countingThreads: Bool) -> [Int32: RestrictedFigures]? {
        guard isAvailable, !pids.isEmpty else { return nil }
        let list = pids.map(String.init).joined(separator: ",")
        let arguments = (countingThreads ? ["-M"] : []) + ["-o", "pid=,time=,rss=", "-p", list]
        guard let output = CommandRunner.run("/bin/ps", arguments, timeout: 1.5) else { return nil }
        return parse(output, countingThreads: countingThreads)
    }

    /// Lines end with "pid time rss". In thread mode ps puts its own columns first and repeats a line per thread.
    private static func parse(_ output: String, countingThreads: Bool) -> [Int32: RestrictedFigures] {
        var figures: [Int32: RestrictedFigures] = [:]
        figures.reserveCapacity(512)
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3,
                  let pid = Int32(fields[fields.count - 3]),
                  let cpuSeconds = seconds(from: fields[fields.count - 2]),
                  let residentKilobytes = UInt64(fields[fields.count - 1]) else { continue }
            if countingThreads, var existing = figures[pid] {
                existing.threadCount = (existing.threadCount ?? 0) + 1
                figures[pid] = existing
            } else {
                figures[pid] = RestrictedFigures(cpuSeconds: cpuSeconds, residentBytes: residentKilobytes * 1024, threadCount: countingThreads ? 1 : nil)
            }
        }
        return figures
    }

    /// "398:20.25" (minutes:seconds) or "1:02:03.40" (hours:minutes:seconds).
    private static func seconds(from text: Substring) -> Double? {
        var total = 0.0
        for component in text.split(separator: ":") {
            guard let value = Double(component) else { return nil }
            total = total * 60 + value
        }
        return total
    }
}
