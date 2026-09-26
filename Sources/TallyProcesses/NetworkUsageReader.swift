import Foundation

/// Bytes each process has moved over its open sockets, from one `nettop` snapshot.
/// nettop runs once per sample rather than as a long-lived child: a streaming nettop block-buffers its
/// output when piped, and an orphaned one spins at full CPU once its reader goes away.
enum NetworkUsageReader {
    struct Totals {
        var bytesIn: UInt64
        var bytesOut: UInt64
    }

    static let isAvailable = FileManager.default.isExecutableFile(atPath: "/usr/bin/nettop")

    static func read() -> [Int32: Totals]? {
        guard isAvailable,
              let output = CommandRunner.run("/usr/bin/nettop", ["-P", "-L", "1", "-x", "-n", "-J", "bytes_in,bytes_out"], timeout: 1.5)
        else { return nil }
        return parse(output)
    }

    /// Lines look like "Google Chrome H.49280,249173651,14621611,". Names are truncated and may contain dots or commas.
    static func parse(_ output: String) -> [Int32: Totals] {
        var totals: [Int32: Totals] = [:]
        for rawLine in output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            var line = rawLine
            if line.last == "," { line = line.dropLast() }
            guard let outComma = line.lastIndex(of: ",") else { continue }
            let head = line[..<outComma]
            guard let inComma = head.lastIndex(of: ","),
                  let bytesOut = UInt64(line[line.index(after: outComma)...]),
                  let bytesIn = UInt64(head[head.index(after: inComma)...]) else { continue }
            let label = head[..<inComma]
            guard let dot = label.lastIndex(of: "."), let pid = Int32(label[label.index(after: dot)...]) else { continue }
            var entry = totals[pid] ?? Totals(bytesIn: 0, bytesOut: 0)
            entry.bytesIn += bytesIn
            entry.bytesOut += bytesOut
            totals[pid] = entry
        }
        return totals
    }
}
