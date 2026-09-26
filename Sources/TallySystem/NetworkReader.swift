import CoreWLAN
import Darwin
import Foundation
import SystemConfiguration
import TallyCore

/// Network throughput from 64-bit interface counters, in total and per connected port, and which interface macOS routes through.
final class NetworkReader {
    private struct InterfaceCounters {
        var bytesIn: UInt64
        var bytesOut: UInt64
        var isRunning: Bool
        /// The line speed the driver reports, in bits per second; 0 while the link is down.
        var baudRate: UInt64
        /// When the kernel last recorded a change to the link, in microseconds.
        var lastChange: Int64
    }

    private struct InterfaceKind {
        var name: String
        var isWireless: Bool
    }

    private var previousCounters: [String: InterfaceCounters] = [:]
    private var previousTime: TimeInterval = 0
    private var lastRates: (download: Double, upload: Double) = (0, 0)
    private var interfaceRates: [String: (download: Double, upload: Double)] = [:]
    private var lastTrafficTimes: [String: TimeInterval] = [:]
    private var sessionDownloaded: UInt64 = 0
    private var sessionUploaded: UInt64 = 0

    private let dynamicStore: SCDynamicStore?
    private var interfaceKinds: [String: InterfaceKind] = [:]
    private var interfaceKindsLoadedAt: TimeInterval = -.infinity

    /// Asking configd for the primary interface, listing addresses and asking Wi-Fi for its rate cost more than
    /// the counters, so the answers are kept for 30 s, and asked again soon after a link or the set of connections changes.
    private var primary: String?
    private var addressedInterfaces: Set<String> = []
    private var wirelessRates: [String: Double] = [:]
    private var connectedAtCheck: Set<String> = []
    private var detailsChanged = false
    private var detailsCheckedAt: TimeInterval = -.infinity
    private var nextDetailsCheck: TimeInterval = -.infinity
    private static let detailsLifetime: TimeInterval = 30
    private static let detailsLifetimeHidden: TimeInterval = 300
    /// Addresses and routes settle a few seconds after a link changes, so a change is checked once more after this.
    private static let settleDelay: TimeInterval = 5
    /// Keeps a link that keeps flapping from asking on every sample.
    private static let minimumCheckSpacing: TimeInterval = 2
    /// How long a port without an address still counts as connected after it last moved data.
    private static let trafficWindow: TimeInterval = 30

    private lazy var wifiClient = CWWiFiClient.shared()

    /// Off screen nobody sees link speeds, so the routine check waits longer; link changes are still noticed at once.
    var isVisible = false {
        didSet {
            if isVisible, !oldValue { nextDetailsCheck = min(nextDetailsCheck, detailsCheckedAt + Self.detailsLifetime) }
        }
    }

    init() {
        dynamicStore = SCDynamicStoreCreate(nil, "Tally" as CFString, nil, nil)
        previousCounters = Self.readCounters()
        previousTime = MonotonicClock.now()
    }

    func read() -> NetworkStats {
        var stats = NetworkStats()
        let now = MonotonicClock.now()
        let current = Self.readCounters()

        var linkChanged = false
        for (name, counters) in current where Self.isPhysical(name) {
            let previous = previousCounters[name]
            if previous?.isRunning != counters.isRunning || previous?.lastChange != counters.lastChange {
                linkChanged = true
                break
            }
        }

        let elapsed = now - previousTime
        if elapsed >= 0.1 {
            var downloaded: UInt64 = 0
            var uploaded: UInt64 = 0
            var rates: [String: (download: Double, upload: Double)] = [:]
            for (name, counters) in current where Self.isPhysical(name) {
                guard let previous = previousCounters[name] else { continue }
                let interfaceDownloaded = counters.bytesIn >= previous.bytesIn ? counters.bytesIn - previous.bytesIn : 0
                let interfaceUploaded = counters.bytesOut >= previous.bytesOut ? counters.bytesOut - previous.bytesOut : 0
                downloaded += interfaceDownloaded
                uploaded += interfaceUploaded
                rates[name] = (Double(interfaceDownloaded) / elapsed, Double(interfaceUploaded) / elapsed)
                if interfaceDownloaded > 0 || interfaceUploaded > 0 { lastTrafficTimes[name] = now }
            }
            sessionDownloaded &+= downloaded
            sessionUploaded &+= uploaded
            lastRates = (Double(downloaded) / elapsed, Double(uploaded) / elapsed)
            interfaceRates = rates
            previousCounters = current
            previousTime = now
        }
        stats.downloadBytesPerSecond = lastRates.download
        stats.uploadBytesPerSecond = lastRates.upload
        stats.sessionDownloadedBytes = sessionDownloaded
        stats.sessionUploadedBytes = sessionUploaded

        var connected = connectedInterfaces(counters: current, now: now)
        let primaryWentDown = primary.map { current[$0]?.isRunning != true } ?? false
        if linkChanged || primaryWentDown || connected != connectedAtCheck { detailsChanged = true }
        if now >= nextDetailsCheck || (detailsChanged && now - detailsCheckedAt >= Self.minimumCheckSpacing) {
            primary = primaryInterface(counters: current)
            addressedInterfaces = Self.addressedInterfaces()
            connected = connectedInterfaces(counters: current, now: now)
            wirelessRates = wirelessTransmitRates(connected, now: now)
            connectedAtCheck = connected
            detailsCheckedAt = now
            nextDetailsCheck = now + (detailsChanged ? Self.settleDelay : isVisible ? Self.detailsLifetime : Self.detailsLifetimeHidden)
            detailsChanged = false
        }

        if let primary {
            stats.interfaceName = primary
            stats.interfaceKind = kind(of: primary, now: now).name
            stats.isConnected = current[primary]?.isRunning ?? true
        }
        stats.connections = connected
            .map { name in
                let kind = kind(of: name, now: now)
                var connection = NetworkConnection(interfaceName: name, kind: kind.name, isWireless: kind.isWireless)
                connection.isPrimary = name == primary
                connection.downloadBytesPerSecond = interfaceRates[name]?.download ?? 0
                connection.uploadBytesPerSecond = interfaceRates[name]?.upload ?? 0
                let baudRate = current[name].map { Double($0.baudRate) } ?? 0
                connection.linkSpeedBitsPerSecond = wirelessRates[name] ?? (baudRate > 0 ? baudRate : nil)
                return connection
            }
            .sorted { lhs, rhs in
                if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
                return lhs.interfaceName.compare(rhs.interfaceName, options: .numeric) == .orderedAscending
            }
        return stats
    }

    /// Wired and wireless ports are all named en*; loopback, tunnels, AWDL, bridges and the like are left out.
    private static func isPhysical(_ name: String) -> Bool {
        name.hasPrefix("en")
    }

    /// Ports that are up and have an address, or moved data lately (a bridge member has no address of its own).
    private func connectedInterfaces(counters: [String: InterfaceCounters], now: TimeInterval) -> Set<String> {
        var names: Set<String> = []
        for (name, interface) in counters where interface.isRunning && Self.isPhysical(name) {
            if addressedInterfaces.contains(name) || now - (lastTrafficTimes[name] ?? -.infinity) < Self.trafficWindow {
                names.insert(name)
            }
        }
        return names
    }

    /// The interface the default route uses. When that is a VPN tunnel, the physical interface carrying it.
    private func primaryInterface(counters: [String: InterfaceCounters]) -> String? {
        guard let dynamicStore else { return nil }
        var primary: String?
        for key in ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] {
            if let value = SCDynamicStoreCopyValue(dynamicStore, key as CFString) as? [String: Any],
               let name = value["PrimaryInterface"] as? String, !name.isEmpty {
                primary = name
                break
            }
        }
        guard let primary else { return nil }
        if Self.isPhysical(primary) { return primary }

        let configured = (SCDynamicStoreCopyKeyList(dynamicStore, "State:/Network/Interface/en[0-9]+/IPv4" as CFString) as? [String]) ?? []
        let physical = configured
            .compactMap { $0.split(separator: "/").dropFirst(3).first.map(String.init) }
            .filter { counters[$0]?.isRunning ?? false }
            .sorted { lhs, rhs in
                let lhsTotal = (counters[lhs]?.bytesIn ?? 0) &+ (counters[lhs]?.bytesOut ?? 0)
                let rhsTotal = (counters[rhs]?.bytesIn ?? 0) &+ (counters[rhs]?.bytesOut ?? 0)
                return lhsTotal > rhsTotal
            }
        return physical.first ?? primary
    }

    /// Physical interfaces with an IPv4 or IPv6 address.
    private static func addressedInterfaces() -> Set<String> {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }
        var names: Set<String> = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            if isPhysical(name) { names.insert(name) }
        }
        return names
    }

    /// Each connected Wi-Fi interface's transmit rate in bits per second. Does not touch the network name,
    /// so it needs no Location permission.
    private func wirelessTransmitRates(_ connected: Set<String>, now: TimeInterval) -> [String: Double] {
        var rates: [String: Double] = [:]
        for name in connected where kind(of: name, now: now).isWireless {
            let megabits = wifiClient.interface(withName: name)?.transmitRate() ?? 0
            if megabits > 0 { rates[name] = megabits * 1_000_000 }
        }
        return rates
    }

    private func kind(of name: String, now: TimeInterval) -> InterfaceKind {
        if let known = interfaceKinds[name] { return known }
        if now - interfaceKindsLoadedAt > 30 {
            interfaceKinds = Self.loadInterfaceKinds()
            interfaceKindsLoadedAt = now
            if let known = interfaceKinds[name] { return known }
        }
        if name.hasPrefix("utun") || name.hasPrefix("ipsec") { return InterfaceKind(name: "VPN", isWireless: false) }
        if name.hasPrefix("ppp") { return InterfaceKind(name: "PPP", isWireless: false) }
        if name.hasPrefix("bridge") { return InterfaceKind(name: "Bridge", isWireless: false) }
        return InterfaceKind(name: name, isWireless: false)
    }

    private static func loadInterfaceKinds() -> [String: InterfaceKind] {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [:] }
        var kinds: [String: InterfaceKind] = [:]
        for interface in interfaces {
            guard let bsdName = SCNetworkInterfaceGetBSDName(interface) as String? else { continue }
            let displayName = (SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?) ?? bsdName
            let type = (SCNetworkInterfaceGetInterfaceType(interface) as String?) ?? ""
            kinds[bsdName] = InterfaceKind(
                name: friendlyKind(displayName: displayName, type: type),
                isWireless: type == (kSCNetworkInterfaceTypeIEEE80211 as String)
            )
        }
        return kinds
    }

    private static func friendlyKind(displayName: String, type: String) -> String {
        let trimmed = displayName.replacingOccurrences(of: #"\s*\(en\d+\)$"#, with: "", options: .regularExpression)
        if type == (kSCNetworkInterfaceTypeIEEE80211 as String) { return trimmed.isEmpty ? "Wi-Fi" : trimmed }
        if type == (kSCNetworkInterfaceTypeEthernet as String) {
            let keepsOwnName = ["Thunderbolt", "iPhone", "iPad"].contains { trimmed.localizedCaseInsensitiveContains($0) }
            return keepsOwnName ? trimmed : "Ethernet"
        }
        return trimmed.isEmpty ? displayName : trimmed
    }

    /// 64-bit byte counters for every interface, keyed by BSD name, from the interface MIB.
    /// (`NET_RT_IFLIST2` now reports these truncated to 32 bits, so they wrap every 4 GB.)
    private static func readCounters() -> [String: InterfaceCounters] {
        var highestIndex: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var countMib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_SYSTEM, IFMIB_IFCOUNT]
        guard sysctl(&countMib, UInt32(countMib.count), &highestIndex, &size, nil, 0) == 0, highestIndex > 0 else { return [:] }

        var counters: [String: InterfaceCounters] = [:]
        var data = ifmibdata()
        for index in 1...highestIndex {
            var length = MemoryLayout<ifmibdata>.size
            var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, index, IFDATA_GENERAL]
            guard sysctl(&mib, UInt32(mib.count), &data, &length, nil, 0) == 0 else { continue }
            let name = withUnsafeBytes(of: data.ifmd_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard !name.isEmpty, counters[name] == nil else { continue }
            let flags = Int32(truncatingIfNeeded: data.ifmd_flags)
            let lastChange = data.ifmd_data.ifi_lastchange
            counters[name] = InterfaceCounters(
                bytesIn: data.ifmd_data.ifi_ibytes,
                bytesOut: data.ifmd_data.ifi_obytes,
                isRunning: flags & IFF_UP != 0 && flags & IFF_RUNNING != 0,
                baudRate: data.ifmd_data.ifi_baudrate,
                lastChange: Int64(lastChange.tv_sec) * 1_000_000 + Int64(lastChange.tv_usec)
            )
        }
        return counters
    }
}
