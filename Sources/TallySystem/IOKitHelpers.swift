import Foundation
import IOKit

/// Small wrappers over IOKit registry calls that return Swift values and never throw.
enum IORegistry {
    static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        guard entry != 0 else { return nil }
        return IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// Looks for a property on the entry, then on its ancestors in the service plane.
    static func searchParents(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        guard entry != 0 else { return nil }
        let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        return IORegistryEntrySearchCFProperty(entry, kIOServicePlane, key as CFString, kCFAllocatorDefault, options)
    }

    /// Every service of a class. The caller owns the returned objects and releases them with `IOObjectRelease`.
    static func services(matching className: String) -> [io_service_t] {
        services(matching: IOServiceMatching(className))
    }

    /// Every service that matches a dictionary. The caller releases them, as above.
    static func services(matching dictionary: CFDictionary?) -> [io_service_t] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, dictionary, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var services: [io_service_t] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            services.append(service)
        }
        return services
    }

    /// Calls `body` with each service of a class and releases it afterwards.
    static func forEachService(matching className: String, _ body: (io_service_t) -> Void) {
        for service in services(matching: className) {
            body(service)
            IOObjectRelease(service)
        }
    }

    /// The first child of `entry` conforming to a class. The caller releases it.
    static func child(of entry: io_registry_entry_t, conformingTo className: String) -> io_registry_entry_t? {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let child = IOIteratorNext(iterator), child != 0 {
            if IOObjectConformsTo(child, className) != 0 { return child }
            IOObjectRelease(child)
        }
        return nil
    }

    static func parent(of entry: io_registry_entry_t) -> io_registry_entry_t? {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS, parent != 0 else { return nil }
        return parent
    }

    static func entryID(_ entry: io_registry_entry_t) -> UInt64 {
        var identifier: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(entry, &identifier)
        return identifier
    }
}

/// Converts loosely typed registry values.
enum RegistryValue {
    static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    static func uint64(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber { return number.uint64Value }
        return nil
    }

    static func bool(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }

    /// Strings are stored either as CFString or as NUL-terminated data (device tree properties).
    static func string(_ value: Any?) -> String? {
        if let string = value as? String { return string.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let data = value as? Data {
            let bytes = data.prefix { $0 != 0 }
            let string = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return string.isEmpty ? nil : string
        }
        return nil
    }
}

enum Sysctl {
    static func int(_ name: String) -> Int? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        switch size {
        case MemoryLayout<Int32>.size:
            var value: Int32 = 0
            guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
            return Int(value)
        case MemoryLayout<Int64>.size:
            var value: Int64 = 0
            guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
            return Int(value)
        default:
            return nil
        }
    }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let string = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return string.isEmpty ? nil : string
    }

    static func value<Value>(_ name: String, initial: Value) -> Value? {
        var value = initial
        var size = MemoryLayout<Value>.size
        let result = withUnsafeMutableBytes(of: &value) { buffer in
            sysctlbyname(name, buffer.baseAddress, &size, nil, 0)
        }
        guard result == 0, size == MemoryLayout<Value>.size else { return nil }
        return value
    }
}

/// Seconds on a clock that keeps running while the Mac sleeps, for rate calculations.
enum MonotonicClock {
    static func now() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }
}
