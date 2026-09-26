import Darwin
import Foundation
import TallyCore

/// Whole-machine and per-core CPU load from `host_processor_info` tick counters.
final class CPUReader {
    private struct CoreTicks {
        var user: UInt32
        var system: UInt32
        var idle: UInt32
        var nice: UInt32
    }

    /// Tick counters advance every 10 ms per core, so shorter windows give jumpy percentages.
    private static let minimumInterval: TimeInterval = 0.25

    private let host = mach_host_self()
    private var previousTicks: [CoreTicks] = []
    private var previousTime: TimeInterval = 0
    private var lastStats: CPUStats?

    let logicalCores: Int
    let performanceCores: Int
    let efficiencyCores: Int
    let chipName: String

    init() {
        let logical = Sysctl.int("hw.logicalcpu") ?? Sysctl.int("hw.ncpu") ?? ProcessInfo.processInfo.activeProcessorCount
        logicalCores = logical
        if let performance = Sysctl.int("hw.perflevel0.logicalcpu"), performance > 0 {
            let levels = Sysctl.int("hw.nperflevels") ?? 1
            performanceCores = performance
            efficiencyCores = levels > 1 ? (Sysctl.int("hw.perflevel1.logicalcpu") ?? max(0, logical - performance)) : 0
        } else {
            performanceCores = logical
            efficiencyCores = 0
        }
        chipName = Self.readChipName()
        previousTicks = readTicks() ?? []
        previousTime = MonotonicClock.now()
    }

    func read() -> CPUStats {
        var stats = CPUStats()
        stats.logicalCores = logicalCores
        stats.performanceCores = performanceCores
        stats.efficiencyCores = efficiencyCores
        stats.chipName = chipName
        stats.loadAverage = Self.loadAverage()

        let now = MonotonicClock.now()
        let isWindowTooShort = now - previousTime < Self.minimumInterval
        if isWindowTooShort, var lastStats {
            lastStats.loadAverage = stats.loadAverage
            return lastStats
        }

        guard let current = readTicks() else { return stats }
        // With no usable window yet (the very first sample), report the average since boot, as top does.
        let hasBaseline = previousTicks.count == current.count && !isWindowTooShort
        var perCore: [Double] = []
        perCore.reserveCapacity(current.count)
        var totalUser: UInt64 = 0
        var totalSystem: UInt64 = 0
        var totalIdle: UInt64 = 0

        for (index, ticks) in current.enumerated() {
            let baseline = hasBaseline ? previousTicks[index] : CoreTicks(user: 0, system: 0, idle: 0, nice: 0)
            let user = UInt64(ticks.user &- baseline.user) + UInt64(ticks.nice &- baseline.nice)
            let system = UInt64(ticks.system &- baseline.system)
            let idle = UInt64(ticks.idle &- baseline.idle)
            let total = user + system + idle
            perCore.append(total == 0 ? 0 : Self.clampPercent(Double(user + system) / Double(total) * 100))
            totalUser += user
            totalSystem += system
            totalIdle += idle
        }
        previousTicks = current
        previousTime = now

        let total = totalUser + totalSystem + totalIdle
        if total > 0 {
            stats.userPercent = Self.clampPercent(Double(totalUser) / Double(total) * 100)
            stats.systemPercent = Self.clampPercent(Double(totalSystem) / Double(total) * 100)
            stats.totalPercent = Self.clampPercent(stats.userPercent + stats.systemPercent)
        }
        stats.perCorePercent = perCore
        lastStats = stats
        return stats
    }

    private func readTicks() -> [CoreTicks]? {
        var processorCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &processorCount, &info, &infoCount) == KERN_SUCCESS, let info else {
            return nil
        }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let stride = Int(CPU_STATE_MAX)
        guard Int(infoCount) >= Int(processorCount) * stride else { return nil }
        var ticks: [CoreTicks] = []
        ticks.reserveCapacity(Int(processorCount))
        for core in 0..<Int(processorCount) {
            let base = core * stride
            ticks.append(CoreTicks(
                user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
            ))
        }
        return ticks
    }

    private static func loadAverage() -> [Double] {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { return [0, 0, 0] }
        return loads
    }

    private static func clampPercent(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(100, max(0, value))
    }

    private static func readChipName() -> String {
        if let brand = Sysctl.string("machdep.cpu.brand_string") {
            return brand.replacingOccurrences(of: "  ", with: " ")
        }
        return ""
    }
}
