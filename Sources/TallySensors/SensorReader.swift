import Foundation
import TallyCore

/// Temperatures, fan speeds and Bluetooth peripheral batteries.
///
/// Temperatures come from the HID event system's on-die sensors when the chip publishes them (M1, M2) and from the
/// SMC otherwise; fans always come from the SMC. Reads follow what is on screen: with nothing visible only the CPU
/// temperature is read (the menu bar item and history use it), while a window or the panel also gets every other
/// group, the fans, and peripheral batteries once a minute. `system_profiler` runs only while something is visible,
/// at most every ten minutes.
public final class SensorReader: SensorSampling, DemandAware {
    private static let peripheralInterval: TimeInterval = 60

    /// Serializes every SMC and HID call.
    private let hardwareQueue = DispatchQueue(label: "tally.sensors.hardware")
    private let lock = NSLock()
    private var demand = SamplingDemand()

    /// Only touched on `hardwareQueue`.
    private var smc: SMCConnection?
    private var temperatureSensors: TemperatureSensors?
    private var fanSensors: FanSensors?
    private var hasDiscovered = false
    private var lastFans: [FanReading] = []

    private let peripherals = PeripheralBatteries()
    private var lastPeripherals: [PeripheralBattery] = []
    private var lastPeripheralRead = -Double.infinity

    public init() {}

    public func setDemand(_ demand: SamplingDemand) {
        lock.lock()
        self.demand = demand
        lock.unlock()
    }

    public func read() -> SensorStats {
        lock.lock()
        defer { lock.unlock() }
        let isVisible = demand.isVisible

        let (temperatures, fans) = hardwareQueue.sync { () -> (TemperatureResult, [FanReading]) in
            discoverIfNeeded()
            let temperatures = temperatureSensors?.read(cpuOnly: !isVisible) ?? TemperatureResult()
            if isVisible { lastFans = fanSensors?.read() ?? [] }
            return (temperatures, lastFans)
        }

        var stats = SensorStats()
        stats.cpuTemperatureCelsius = temperatures.cpu
        stats.gpuTemperatureCelsius = temperatures.gpu
        stats.temperatures = temperatures.readings
        stats.fans = fans

        let now = ProcessInfo.processInfo.systemUptime
        if isVisible, now - lastPeripheralRead >= Self.peripheralInterval * demand.intervalScale || peripherals.hasUnreadProfilerResult {
            lastPeripherals = peripherals.read()
            lastPeripheralRead = now
        }
        stats.peripheralBatteries = lastPeripherals
        return stats
    }

    private func discoverIfNeeded() {
        guard !hasDiscovered else { return }
        hasDiscovered = true
        smc = SMCConnection()
        temperatureSensors = TemperatureSensors(smc: smc)
        fanSensors = smc.map(FanSensors.init)
    }

    /// Every raw source this Mac exposes and what was read from it, for diagnostics. Blocks while it reads.
    public func inventory() -> String {
        var lines: [String] = hardwareQueue.sync {
            discoverIfNeeded()
            var lines = temperatureSensors?.inventory() ?? []
            if let smc {
                let count = smc.value("FNum").map { Int($0) } ?? 0
                lines.append("Fans: \(count) reported by FNum")
                for index in 0..<min(count, 8) {
                    let keys = ["Ac", "Mn", "Mx", "Tg"].map { suffix -> String in
                        let key = "F\(index)\(suffix)"
                        return "\(key)=" + (smc.value(key).map { String(format: "%.0f", $0) } ?? "--")
                    }
                    lines.append("  " + keys.joined(separator: " "))
                }
            }
            return lines
        }
        lines += peripherals.inventory()
        return lines.joined(separator: "\n")
    }
}
