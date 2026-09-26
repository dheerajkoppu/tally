import Darwin
import Foundation
import IOKit

/// Facts about the Mac that do not change while Tally runs, and the time since boot.
enum MachineInfo {
    /// "MacBook Pro", "Mac mini", "iMac".
    static let name: String = {
        if let product = productName() {
            let family = product.replacingOccurrences(of: #"\s*\(.*\)\s*$"#, with: "", options: .regularExpression)
            if !family.isEmpty { return family }
        }
        return familyName(fromModel: Sysctl.string("hw.model") ?? "")
    }()

    static func uptime() -> TimeInterval {
        guard let bootTime = Sysctl.value("kern.boottime", initial: timeval()), bootTime.tv_sec > 0 else {
            return ProcessInfo.processInfo.systemUptime
        }
        let boot = TimeInterval(bootTime.tv_sec) + TimeInterval(bootTime.tv_usec) / 1_000_000
        return max(0, Date().timeIntervalSince1970 - boot)
    }

    /// The marketing name in the device tree on Apple silicon, e.g. "MacBook Pro (14-inch, Nov 2024)".
    private static func productName() -> String? {
        let product = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard product != 0 else { return nil }
        defer { IOObjectRelease(product) }
        return RegistryValue.string(IORegistry.property(product, "product-name"))
    }

    /// Intel Macs report identifiers like "MacBookPro16,1".
    private static func familyName(fromModel model: String) -> String {
        let families: [(prefix: String, name: String)] = [
            ("MacBookPro", "MacBook Pro"), ("MacBookAir", "MacBook Air"), ("MacBook", "MacBook"),
            ("Macmini", "Mac mini"), ("MacPro", "Mac Pro"), ("iMacPro", "iMac Pro"), ("iMac", "iMac"),
            ("Mac", "Mac"), ("VirtualMac", "Virtual Mac"),
        ]
        for family in families where model.hasPrefix(family.prefix) {
            return family.name
        }
        return model.isEmpty ? "Mac" : model
    }
}
