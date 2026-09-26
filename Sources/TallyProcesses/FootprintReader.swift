import Foundation

/// Physical footprint (Activity Monitor's Memory) of other users' processes, such as WindowServer.
/// Only top, which is setuid root, can read it. top inspects every task and costs about a third of a CPU
/// second per run, so it runs rarely and in the background; ps's resident size fills in between.
enum FootprintReader {
    static let isAvailable = FileManager.default.isExecutableFile(atPath: "/usr/bin/top")

    static func read() -> [Int32: UInt64]? {
        guard isAvailable,
              let output = CommandRunner.run("/usr/bin/top", ["-l", "1", "-F", "-R", "-n", "10000", "-stats", "pid,mem"], timeout: 5)
        else { return nil }
        var footprints: [Int32: UInt64] = [:]
        var inTable = false
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2 else { continue }
            if !inTable {
                inTable = fields[0] == "PID"
                continue
            }
            guard let pid = Int32(fields[0]), let bytes = bytes(from: fields[1]) else { continue }
            footprints[pid] = bytes
        }
        return footprints.isEmpty ? nil : footprints
    }

    /// "786M", "6912K", "1.2G", "0B", sometimes followed by a trend sign.
    private static func bytes(from text: Substring) -> UInt64? {
        var value = text
        while let last = value.last, last == "+" || last == "-" { value = value.dropLast() }
        guard let unit = value.last else { return nil }
        let multipliers: [Character: Double] = ["B": 1, "K": 1024, "M": 1024 * 1024, "G": 1024 * 1024 * 1024, "T": 1024 * 1024 * 1024 * 1024]
        if let multiplier = multipliers[unit], let number = Double(value.dropLast()) {
            return UInt64(number * multiplier)
        }
        return Double(value).map { UInt64($0) }
    }
}
