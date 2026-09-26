import Foundation
import IOKit
import TallyCore

/// GPU utilization and memory from the IOAccelerator performance statistics.
final class GPUReader {
    private struct Reading {
        var utilization: Double
        var memory: UInt64
        var name: String
    }

    private let chipName: String
    private var names: [UInt64: String] = [:]

    init(chipName: String) {
        self.chipName = chipName
    }

    /// When a Mac has several GPUs (Intel with a discrete card), reports the busiest one.
    func read() -> GPUStats {
        var busiest: Reading?
        IORegistry.forEachService(matching: "IOAccelerator") { accelerator in
            guard let statistics = IORegistry.property(accelerator, "PerformanceStatistics") as? NSDictionary else { return }
            let utilization = Self.number(statistics, ["Device Utilization %", "GPU Activity(%)"]) ?? 0
            let memory = RegistryValue.uint64(statistics["In use system memory"])
                ?? RegistryValue.uint64(statistics["Alloc system memory"])
                ?? RegistryValue.uint64(statistics["vramUsedBytes"])
                ?? 0
            if let current = busiest, current.utilization >= utilization { return }
            busiest = Reading(utilization: utilization, memory: memory, name: name(of: accelerator))
        }

        var stats = GPUStats()
        guard let busiest else {
            stats.name = appleSiliconName ?? ""
            return stats
        }
        stats.name = busiest.name
        stats.utilizationPercent = min(100, max(0, busiest.utilization))
        stats.memoryUsedBytes = busiest.memory
        return stats
    }

    private var appleSiliconName: String? {
        chipName.hasPrefix("Apple") ? chipName : nil
    }

    private func name(of accelerator: io_registry_entry_t) -> String {
        if let appleSiliconName { return appleSiliconName }
        let identifier = IORegistry.entryID(accelerator)
        if let known = names[identifier] { return known }
        let model = RegistryValue.string(IORegistry.property(accelerator, "model"))
            ?? RegistryValue.string(IORegistry.searchParents(accelerator, "model"))
            ?? "GPU"
        names[identifier] = model
        return model
    }

    private static func number(_ statistics: NSDictionary, _ keys: [String]) -> Double? {
        for key in keys {
            if let number = statistics[key] as? NSNumber { return number.doubleValue }
        }
        return nil
    }
}
