import Foundation
import IOKit

/// Accumulated GPU time per process, from the GPU driver's user clients in the IORegistry.
/// Each client carries "IOUserClientCreator" = "pid 1234, Name" and an "AppUsage" array of
/// per-queue dictionaries with "accumulatedGPUTime" in nanoseconds.
enum GPUUsageReader {
    private static let creatorKey = "IOUserClientCreator" as CFString
    private static let usageKey = "AppUsage" as CFString
    private static let timeKey = "accumulatedGPUTime" as NSString

    static func accumulatedNanoseconds() -> [Int32: UInt64] {
        var totals: [Int32: UInt64] = [:]
        var accelerators: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &accelerators) == KERN_SUCCESS else {
            return totals
        }
        defer { IOObjectRelease(accelerators) }
        var accelerator = IOIteratorNext(accelerators)
        while accelerator != 0 {
            var clients: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &clients) == KERN_SUCCESS {
                var client = IOIteratorNext(clients)
                while client != 0 {
                    if let (pid, nanoseconds) = usage(of: client) {
                        totals[pid, default: 0] &+= nanoseconds
                    }
                    IOObjectRelease(client)
                    client = IOIteratorNext(clients)
                }
                IOObjectRelease(clients)
            }
            IOObjectRelease(accelerator)
            accelerator = IOIteratorNext(accelerators)
        }
        return totals
    }

    /// Reads the usage list first, since most clients have none, and walks it as Foundation objects without bridging.
    private static func usage(of client: io_registry_entry_t) -> (Int32, UInt64)? {
        guard let entries = IORegistryEntryCreateCFProperty(client, usageKey, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSArray,
              entries.count > 0,
              let creator = IORegistryEntryCreateCFProperty(client, creatorKey, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
              let pid = pid(fromCreator: creator)
        else { return nil }
        var total: UInt64 = 0
        for case let entry as NSDictionary in entries {
            if let time = entry[timeKey] as? NSNumber { total &+= time.uint64Value }
        }
        return (pid, total)
    }

    /// "pid 1234, Google Chrome He" → 1234
    private static func pid(fromCreator creator: String) -> Int32? {
        guard creator.hasPrefix("pid ") else { return nil }
        let digits = creator.dropFirst(4).prefix { $0.isNumber }
        return Int32(digits)
    }
}
