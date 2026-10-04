import Darwin
import Foundation
import TallyCore

/// Memory split the way Activity Monitor reports it, plus swap and memory pressure.
final class MemoryReader {
    private let host = mach_host_self()
    private let pageSize: UInt64
    private let totalBytes: UInt64

    init() {
        var size: vm_size_t = 0
        if host_page_size(host, &size) == KERN_SUCCESS, size > 0 {
            pageSize = UInt64(size)
        } else {
            pageSize = UInt64(Sysctl.int("hw.pagesize") ?? 16384)
        }
        totalBytes = UInt64(Sysctl.int("hw.memsize") ?? Int(ProcessInfo.processInfo.physicalMemory))
    }

    func read() -> MemoryStats {
        var stats = MemoryStats()
        stats.totalBytes = totalBytes

        if let vm = Self.vmStatistics(host: host) {
            let internalPages = UInt64(vm.internal_page_count)
            let purgeablePages = UInt64(vm.purgeable_count)
            let freePages = UInt64(vm.free_count)
            let speculativePages = UInt64(vm.speculative_count)
            stats.appBytes = (internalPages > purgeablePages ? internalPages - purgeablePages : 0) * pageSize
            stats.wiredBytes = UInt64(vm.wire_count) * pageSize
            stats.compressedBytes = UInt64(vm.compressor_page_count) * pageSize
            stats.cachedBytes = (UInt64(vm.external_page_count) + purgeablePages) * pageSize
            stats.freeBytes = (freePages > speculativePages ? freePages - speculativePages : 0) * pageSize
            let fileBackedBytes = UInt64(vm.external_page_count) * pageSize
            stats.usedBytes = totalBytes > stats.freeBytes + fileBackedBytes ? totalBytes - stats.freeBytes - fileBackedBytes : 0
        }

        if let swap = Sysctl.value("vm.swapusage", initial: xsw_usage()) {
            stats.swapUsedBytes = UInt64(swap.xsu_used)
            stats.swapTotalBytes = UInt64(swap.xsu_total)
        }

        switch Sysctl.int("kern.memorystatus_vm_pressure_level") ?? 1 {
        case 4: stats.pressure = .critical
        case 2: stats.pressure = .warning
        default: stats.pressure = .normal
        }
        return stats
    }

    private static func vmStatistics(host: host_t) -> vm_statistics64? {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        return result == KERN_SUCCESS ? statistics : nil
    }
}
