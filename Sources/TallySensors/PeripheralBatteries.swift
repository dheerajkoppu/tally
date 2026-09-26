import Foundation
import IOKit
import IOKit.ps
import TallyCore

private typealias CopyPowerSourcesByType = @convention(c) (Int32) -> UnsafeMutableRawPointer?

/// One device's battery as a single source reports it, before sources are merged.
struct PeripheralCandidate {
    var name: String
    var percent: Double
    var kind: PeripheralKind
    /// Bluetooth address as "AA:BB:CC:DD:EE:FF", when the source knows it.
    var address: String?
}

/// Bluetooth peripheral batteries from three sources, freshest first:
/// the power source list (AirPods, Magic devices, BLE mice), the IORegistry (BatteryPercent on HID services)
/// and `system_profiler SPBluetoothDataType`, which is slow and runs in the background at most every ten minutes.
/// The owner calls `read()` only while batteries can be on screen, so the profiler never runs for nobody.
final class PeripheralBatteries {
    /// kIOPSSourceForAccessories in IOPSKeysPrivate.h.
    private static let accessorySourceType: Int32 = 4
    private static let profilerInterval: TimeInterval = 600
    /// A device appearing or leaving refreshes the profiler cache sooner, but never more often than this.
    private static let profilerMinimumSpacing: TimeInterval = 60
    private static let profilerTimeout: TimeInterval = 20

    private static let copyPowerSourcesByType: CopyPowerSourcesByType? = {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
              let pointer = dlsym(handle, "IOPSCopyPowerSourcesByType") else { return nil }
        return unsafeBitCast(pointer, to: CopyPowerSourcesByType.self)
    }()

    private let queue = DispatchQueue(label: "tally.sensors.bluetooth", qos: .utility)
    private let lock = NSLock()
    private var profilerDevices: [PeripheralCandidate] = []
    private var profilerNamesByAddress: [String: String] = [:]
    private var lastProfilerStart = Date.distantPast
    private var profilerRunning = false
    private var profilerResultIsUnread = false

    /// Only touched from `read()`, which the owner serializes.
    private var lastLiveIdentities = Set<String>()
    private var powerSourceNamesSeen = Set<String>()

    /// A system_profiler run finished since the last `read()`.
    var hasUnreadProfilerResult: Bool {
        lock.lock()
        defer { lock.unlock() }
        return profilerResultIsUnread
    }

    func read() -> [PeripheralBattery] {
        lock.lock()
        let cachedProfilerDevices = profilerDevices
        let namesByAddress = profilerNamesByAddress
        profilerResultIsUnread = false
        lock.unlock()

        let powerSources = Self.powerSourceAccessories()
        let registry = Self.registryAccessories(namesByAddress: namesByAddress)

        let currentPowerSourceNames = Set(powerSources.map { Self.normalizedName($0.name) })
        powerSourceNamesSeen.formUnion(currentPowerSourceNames)
        // The power source list is authoritative for devices it has tracked: once it drops one, the device is gone.
        let profiler = cachedProfilerDevices.filter { candidate in
            let name = Self.normalizedName(candidate.name)
            return !powerSourceNamesSeen.contains(name) || currentPowerSourceNames.contains(name)
        }

        let liveIdentities = Set((powerSources + registry).map { $0.address ?? Self.normalizedName($0.name) })
        refreshProfilerIfNeeded(accessoriesChanged: liveIdentities != lastLiveIdentities)
        lastLiveIdentities = liveIdentities

        return Self.merge([powerSources, registry, profiler])
    }

    static func powerSourceAccessories() -> [PeripheralCandidate] {
        guard let copy = copyPowerSourcesByType, let pointer = copy(accessorySourceType) else { return [] }
        let blob = Unmanaged<CFTypeRef>.fromOpaque(pointer).takeRetainedValue()
        guard let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return [] }
        return list.compactMap { source in
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any] else { return nil }
            return candidate(fromPowerSource: description)
        }
    }

    static func candidate(fromPowerSource description: [String: Any]) -> PeripheralCandidate? {
        guard (description["Type"] as? String) != "InternalBattery" else { return nil }
        if let present = description["Is Present"] as? Bool, !present { return nil }
        let category = description["Accessory Category"] as? String ?? ""
        let part = description["Part Identifier"] as? String ?? ""
        if part == "Case" || category.localizedCaseInsensitiveContains("case") { return nil }
        guard let name = (description["Name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        // AirPods report each bud as a part; the lower one is the one that runs out first.
        let parts = (description["Combined Parts"] as? [[String: Any]] ?? []).filter { ($0["Is Present"] as? Bool) ?? true }
        guard let percent = parts.compactMap(percent(fromPowerSource:)).min() ?? percent(fromPowerSource: description) else { return nil }
        let address = (description["Accessory Identifier"] as? String).flatMap(normalizedAddress)
        return PeripheralCandidate(name: name, percent: percent, kind: kind(category: category, name: name), address: address)
    }

    private static func percent(fromPowerSource description: [String: Any]) -> Double? {
        guard let current = (description["Current Capacity"] as? NSNumber)?.doubleValue else { return nil }
        let maximum = (description["Max Capacity"] as? NSNumber)?.doubleValue ?? 100
        guard maximum > 0 else { return nil }
        return clampedPercent(current / maximum * 100)
    }

    static func registryAccessories(namesByAddress: [String: String]) -> [PeripheralCandidate] {
        var results: [PeripheralCandidate] = []
        var seenEntries = Set<UInt64>()
        let matchings: [CFDictionary] = [
            ["IOPropertyExistsMatch": ["BatteryPercent"]] as CFDictionary,
            IOServiceMatching("AppleDeviceManagementHIDEventService"),
        ]
        for matching in matchings {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }
            var entry = IOIteratorNext(iterator)
            while entry != 0 {
                var entryID: UInt64 = 0
                IORegistryEntryGetRegistryEntryID(entry, &entryID)
                if seenEntries.insert(entryID).inserted, let candidate = candidate(fromRegistryEntry: entry, namesByAddress: namesByAddress) {
                    results.append(candidate)
                }
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }
        }
        return results
    }

    private static func candidate(fromRegistryEntry entry: io_registry_entry_t, namesByAddress: [String: String]) -> PeripheralCandidate? {
        func property(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        guard let percent = (property("BatteryPercent") as? NSNumber)?.doubleValue else { return nil }
        if (property("Built-In") as? Bool) == true { return nil }
        let address = (property("DeviceAddress") as? String).flatMap(normalizedAddress)
        let category = property("Accessory Category") as? String ?? ""
        var name = (property("Product") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.isEmpty, let address, let known = namesByAddress[address] { name = known }
        if name.isEmpty {
            let isApple = (property("VendorID") as? NSNumber)?.intValue == 76
            name = fallbackName(category: category, isApple: isApple)
        }
        return PeripheralCandidate(name: name, percent: clampedPercent(percent), kind: kind(category: category, name: name), address: address)
    }

    private static func fallbackName(category: String, isApple: Bool) -> String {
        switch kind(category: category, name: "") {
        case .keyboard: isApple ? "Magic Keyboard" : "Keyboard"
        case .mouse: isApple ? "Magic Mouse" : "Mouse"
        case .trackpad: isApple ? "Magic Trackpad" : "Trackpad"
        case .gameController: "Game Controller"
        case .headphones: "Headphones"
        case .other: category.isEmpty ? "Bluetooth Accessory" : category
        }
    }

    private func refreshProfilerIfNeeded(accessoriesChanged: Bool) {
        lock.lock()
        let elapsed = Date().timeIntervalSince(lastProfilerStart)
        let isDue = elapsed >= Self.profilerInterval || (accessoriesChanged && elapsed >= Self.profilerMinimumSpacing)
        guard isDue, !profilerRunning else {
            lock.unlock()
            return
        }
        profilerRunning = true
        lastProfilerStart = Date()
        lock.unlock()

        queue.async { [weak self] in
            let parsed = Self.runSystemProfiler().map(Self.parseProfiler)
            guard let self else { return }
            self.lock.lock()
            self.profilerDevices = parsed?.devices ?? []
            self.profilerNamesByAddress = parsed?.namesByAddress ?? [:]
            self.profilerRunning = false
            self.profilerResultIsUnread = true
            self.lock.unlock()
        }
    }

    /// Runs system_profiler with its output going to a temporary file, so a stuck helper can never block a pipe read.
    private static func runSystemProfiler() -> Data? {
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("tally-bluetooth-\(UUID().uuidString).json")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
              let output = try? FileHandle(forWritingTo: outputURL) else { return nil }
        defer {
            try? output.close()
            try? FileManager.default.removeItem(at: outputURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json", "-timeout", String(Int(profilerTimeout))]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.qualityOfService = .utility
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        if finished.wait(timeout: .now() + profilerTimeout + 5) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 2)
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return try? Data(contentsOf: outputURL)
    }

    static func parseProfiler(_ data: Data) -> (devices: [PeripheralCandidate], namesByAddress: [String: String]) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return ([], [:]) }
        var devices: [PeripheralCandidate] = []
        var namesByAddress: [String: String] = [:]
        for controller in controllers {
            for entry in controller["device_connected"] as? [[String: Any]] ?? [] {
                for (rawName, value) in entry {
                    guard let properties = value as? [String: Any] else { continue }
                    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let address = (properties["device_address"] as? String).flatMap(normalizedAddress)
                    if let address { namesByAddress[address] = name }
                    guard let percent = profilerPercent(properties) else { continue }
                    let minorType = properties["device_minorType"] as? String ?? ""
                    devices.append(PeripheralCandidate(name: name, percent: percent, kind: kind(category: minorType, name: name), address: address))
                }
            }
        }
        return (devices, namesByAddress)
    }

    private static func profilerPercent(_ properties: [String: Any]) -> Double? {
        func level(_ key: String) -> Double? {
            if let number = properties[key] as? NSNumber { return number.doubleValue }
            guard let text = properties[key] as? String else { return nil }
            return Double(text.filter { $0.isNumber || $0 == "." })
        }
        let buds = [level("device_batteryLevelLeft"), level("device_batteryLevelRight")].compactMap { $0 }
        let percent = buds.min() ?? level("device_batteryLevelMain") ?? level("device_batteryLevel") ?? level("device_batteryPercent")
        return percent.map(clampedPercent)
    }

    static func merge(_ sources: [[PeripheralCandidate]]) -> [PeripheralBattery] {
        var accepted: [PeripheralCandidate] = []
        var acceptedAddresses = Set<String>()
        var acceptedNames = Set<String>()
        for source in sources {
            var sourceNames = Set<String>()
            for candidate in source {
                let name = normalizedName(candidate.name)
                if let address = candidate.address, acceptedAddresses.contains(address) { continue }
                // The same device reported by an earlier, fresher source.
                if acceptedNames.contains(name) { continue }
                accepted.append(candidate)
                sourceNames.insert(name)
                if let address = candidate.address { acceptedAddresses.insert(address) }
            }
            acceptedNames.formUnion(sourceNames)
        }

        accepted.sort { lhs, rhs in
            let lhsOrder = kindOrder(lhs.kind)
            let rhsOrder = kindOrder(rhs.kind)
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        // Identifiable by name, so two identical devices need distinct names.
        var usedNames = Set<String>()
        return accepted.map { candidate in
            let productName = displayName(candidate.name)
            var name = productName
            var suffix = 2
            while usedNames.contains(name) {
                name = "\(productName) \(suffix)"
                suffix += 1
            }
            usedNames.insert(name)
            return PeripheralBattery(name: name, percent: candidate.percent, kind: candidate.kind)
        }
    }

    private static func kindOrder(_ kind: PeripheralKind) -> Int {
        switch kind {
        case .headphones: 0
        case .mouse: 1
        case .keyboard: 2
        case .trackpad: 3
        case .gameController: 4
        case .other: 5
        }
    }

    static func kind(category: String, name: String) -> PeripheralKind {
        if let kind = kind(matching: category.lowercased()) { return kind }
        return kind(matching: name.lowercased()) ?? .other
    }

    private static func kind(matching text: String) -> PeripheralKind? {
        guard !text.isEmpty else { return nil }
        if text.contains("trackpad") { return .trackpad }
        if text.contains("mouse") || text.contains("mx master") || text.contains("mx anywhere") { return .mouse }
        if text.contains("keyboard") || text.contains("keypad") || text.contains("mx keys") { return .keyboard }
        if ["gamepad", "game controller", "controller", "joystick", "dualsense", "dualshock"].contains(where: text.contains) { return .gameController }
        if ["headphone", "headset", "airpods", "beats", "earbud", "buds"].contains(where: text.contains) { return .headphones }
        return nil
    }

    /// "Alex’s AirPods Pro" becomes "AirPods Pro", which fits a compact tile; names without an owner stay as they are.
    static func displayName(_ name: String) -> String {
        for marker in ["\u{2019}s ", "'s ", "s\u{2019} ", "s' "] {
            guard let range = name.range(of: marker), range.lowerBound > name.startIndex else { continue }
            let product = name[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard let first = product.first, first.isUppercase || first.isNumber else { continue }
            return product
        }
        return name
    }

    static func normalizedName(_ name: String) -> String {
        name.replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    /// "38-09-fb-1d-a3-80" and "38:09:FB:1D:A3:80" both become "38:09:FB:1D:A3:80"; anything else is not an address.
    static func normalizedAddress(_ text: String) -> String? {
        let parts = text.split(whereSeparator: { $0 == ":" || $0 == "-" })
        guard parts.count == 6, parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) }) else { return nil }
        return parts.map { $0.uppercased() }.joined(separator: ":")
    }

    private static func clampedPercent(_ value: Double) -> Double {
        value.isFinite ? min(100, max(0, value)) : 0
    }

    /// A description of every raw source, for the probe.
    func inventory() -> [String] {
        lock.lock()
        let cachedProfilerDevices = profilerDevices
        lock.unlock()
        func describe(_ candidates: [PeripheralCandidate]) -> String {
            candidates.isEmpty ? "none" : candidates.map { "\($0.name) \(Int($0.percent))% \($0.kind.rawValue)\($0.address.map { " [\($0)]" } ?? "")" }.joined(separator: "; ")
        }
        return [
            "Power sources: " + describe(Self.powerSourceAccessories()),
            "IORegistry: " + describe(Self.registryAccessories(namesByAddress: [:])),
            "system_profiler: " + describe(cachedProfilerDevices),
        ]
    }
}
