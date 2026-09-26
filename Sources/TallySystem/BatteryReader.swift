import Foundation
import IOKit
import IOKit.ps
import TallyCore

/// Battery charge, health, temperature and power draw from the AppleSmartBattery service, checked against the
/// power source info macOS shows in the menu bar.
///
/// Charge and power draw are cheap top-level properties read every sample. Health, cycle count, temperature and the
/// adapter live in the large BatteryData dictionary (or change only on plugging in), so they are read once a minute
/// while something is on screen, every five minutes otherwise, and whenever the charger is connected or removed.
final class BatteryReader {
    private struct SlowFigures {
        var date: TimeInterval
        var isPluggedIn: Bool
        var cycleCount: Int
        var designCapacity: Int
        var maximumCapacity: Int
        var temperatureCelsius: Double
        var adapterWatts: Int?
    }

    /// The gas gauge reports 65535 when it has no estimate.
    private static let unknownTime = 65535
    private static let slowRefreshVisible: TimeInterval = 60
    private static let slowRefreshHidden: TimeInterval = 300

    /// Set by the owner before each sample.
    var isVisible = false

    private var battery: io_service_t = 0
    private var pack: io_registry_entry_t = 0
    private var slowFigures: SlowFigures?
    private let healthReader = BatteryHealthReader()

    init() {
        battery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if battery != 0 {
            pack = IORegistry.child(of: battery, conformingTo: "AppleSmartBatteryPack") ?? 0
        }
    }

    deinit {
        if pack != 0 { IOObjectRelease(pack) }
        if battery != 0 { IOObjectRelease(battery) }
    }

    func read() -> BatteryStats {
        var stats = BatteryStats()
        let powerSource = PowerSource.internalBattery()
        let properties = BatteryProperties(battery: battery, pack: pack)
        let isInstalled = battery != 0 && (RegistryValue.bool(properties.topLevel("BatteryInstalled")) ?? true)
        guard isInstalled || powerSource != nil else { return stats }
        stats.hasBattery = true

        if let powerSource, let current = powerSource.currentCapacity, let maximum = powerSource.maxCapacity, maximum > 0 {
            stats.percent = Double(current) / Double(maximum) * 100
        } else if let current = properties.int("CurrentCapacity"), let maximum = properties.int("MaxCapacity"), maximum > 0 {
            stats.percent = Double(current) / Double(maximum) * 100
        }
        stats.percent = min(100, max(0, stats.percent))

        stats.isPluggedIn = RegistryValue.bool(properties.topLevel("ExternalConnected")) ?? powerSource?.isOnACPower ?? false
        stats.isCharging = powerSource?.isCharging ?? RegistryValue.bool(properties.topLevel("IsCharging")) ?? false
        stats.timeRemainingMinutes = timeRemaining(stats: stats, powerSource: powerSource, properties: properties)
        stats.powerDrawWatts = powerDraw(isPluggedIn: stats.isPluggedIn, properties: properties)

        let now = MonotonicClock.now()
        let refreshInterval = isVisible ? Self.slowRefreshVisible : Self.slowRefreshHidden
        let slow: SlowFigures
        if let cached = slowFigures, cached.isPluggedIn == stats.isPluggedIn, now - cached.date < refreshInterval {
            slow = cached
        } else {
            slow = readSlowFigures(isPluggedIn: stats.isPluggedIn, properties: properties, now: now)
            slowFigures = slow
        }
        stats.cycleCount = slow.cycleCount
        stats.designCapacitymAh = slow.designCapacity
        stats.maxCapacitymAh = slow.maximumCapacity
        if let systemFigure = healthReader.current(now: now) {
            stats.healthPercent = systemFigure
        } else if slow.designCapacity > 0, slow.maximumCapacity > 0 {
            let ratio = Double(slow.maximumCapacity) / Double(slow.designCapacity) * 100
            stats.healthPercent = min(100, ratio.rounded())
        }
        stats.temperatureCelsius = slow.temperatureCelsius
        stats.adapterWatts = slow.adapterWatts
        return stats
    }

    private func readSlowFigures(isPluggedIn: Bool, properties: BatteryProperties, now: TimeInterval) -> SlowFigures {
        var temperature = 0.0
        for key in ["Temperature", "VirtualTemperature"] {
            if let centiCelsius = properties.int(key), centiCelsius > 0 {
                let celsius = Double(centiCelsius) / 100
                if celsius < 120 {
                    temperature = celsius
                    break
                }
            }
        }
        var adapterWatts: Int?
        if isPluggedIn {
            let adapter = properties.topLevel("AdapterDetails") as? [String: Any] ?? PowerSource.adapterDetails()
            if let watts = RegistryValue.int(adapter?["Watts"]), watts > 0 { adapterWatts = watts }
        }
        return SlowFigures(
            date: now,
            isPluggedIn: isPluggedIn,
            cycleCount: properties.int("CycleCount") ?? 0,
            designCapacity: properties.int("DesignCapacity") ?? 0,
            maximumCapacity: properties.int("NominalChargeCapacity") ?? properties.int("AppleRawMaxCapacity") ?? 0,
            temperatureCelsius: temperature,
            adapterWatts: adapterWatts
        )
    }

    private func timeRemaining(stats: BatteryStats, powerSource: PowerSource?, properties: BatteryProperties) -> Int? {
        func valid(_ minutes: Int?) -> Int? {
            guard let minutes, minutes > 0, minutes < Self.unknownTime else { return nil }
            return minutes
        }
        if stats.isCharging {
            return valid(powerSource?.timeToFull) ?? valid(properties.int("AvgTimeToFull"))
        }
        if !stats.isPluggedIn {
            return valid(powerSource?.timeToEmpty) ?? valid(properties.int("TimeRemaining")) ?? valid(properties.int("AvgTimeToEmpty"))
        }
        return nil
    }

    private func powerDraw(isPluggedIn: Bool, properties: BatteryProperties) -> Double {
        if isPluggedIn, let telemetry = properties.topLevel("PowerTelemetryData") as? [String: Any] {
            for key in ["SystemPowerIn", "SystemLoad"] {
                if let milliwatts = RegistryValue.int(telemetry[key]), milliwatts > 0, milliwatts < 1_000_000 {
                    return Double(milliwatts) / 1000
                }
            }
        }
        guard let millivolts = properties.int("Voltage") ?? properties.int("AppleRawBatteryVoltage") else { return 0 }
        var milliamps = properties.int("InstantAmperage") ?? 0
        if milliamps == 0 { milliamps = properties.int("Amperage") ?? 0 }
        return abs(Double(millivolts) * Double(milliamps)) / 1_000_000
    }
}

/// Reads battery keys from wherever this macOS version keeps them: the battery service itself, its
/// `BatteryData` dictionary, or (newer releases) the `AppleSmartBatteryPack` child's `BatteryData`.
/// The dictionaries are large, so each is fetched only when a key is missing from the level above.
private final class BatteryProperties {
    let battery: io_service_t
    let pack: io_registry_entry_t
    private lazy var batteryData: NSDictionary? = IORegistry.property(battery, "BatteryData") as? NSDictionary
    private lazy var packData: NSDictionary? = pack != 0 ? IORegistry.property(pack, "BatteryData") as? NSDictionary : nil

    init(battery: io_service_t, pack: io_registry_entry_t) {
        self.battery = battery
        self.pack = pack
    }

    func topLevel(_ key: String) -> Any? {
        IORegistry.property(battery, key)
    }

    func int(_ key: String) -> Int? {
        RegistryValue.int(topLevel(key)) ?? RegistryValue.int(batteryData?[key]) ?? RegistryValue.int(packData?[key])
    }
}

/// The internal battery as the IOPowerSources API describes it (the figures the menu bar shows).
private struct PowerSource {
    var currentCapacity: Int?
    var maxCapacity: Int?
    var isCharging: Bool?
    var isOnACPower: Bool
    var timeToEmpty: Int?
    var timeToFull: Int?

    static func internalBattery() -> PowerSource? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  description[kIOPSIsPresentKey] as? Bool ?? true else { continue }
            return PowerSource(
                currentCapacity: description[kIOPSCurrentCapacityKey] as? Int,
                maxCapacity: description[kIOPSMaxCapacityKey] as? Int,
                isCharging: description[kIOPSIsChargingKey] as? Bool,
                isOnACPower: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                timeToEmpty: description[kIOPSTimeToEmptyKey] as? Int,
                timeToFull: description[kIOPSTimeToFullChargeKey] as? Int
            )
        }
        return nil
    }

    static func adapterDetails() -> [String: Any]? {
        IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any]
    }
}
